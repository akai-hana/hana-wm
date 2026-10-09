//! Brightness slider sub.
//! Shows the display backlight level and controls it, bound to the slider
//! core's `Sub` contract. This module owns the device's TRUTH -- sysfs
//! discovery, reads, writes, and the display format -- while the slider core
//! owns the shared render shell, interaction, poll, and commit clock.
//!
//! Backend: controlled through the kernel's own sysfs interface --
//! `/sys/class/backlight/<dev>/brightness` plus `max_brightness` -- which is
//! exactly what userspace tools like `brightnessctl` wrap. Direct sysfs I/O
//! needs no tool and no subprocess spawn, and with a write policy (user in
//! `video`, the shipped `contrib/udev/90-hana-backlight.rules`) a commit is
//! one tiny file write, so drags need no throttle. A `brightnessctl`
//! subprocess is used only as a fallback when a direct write is denied
//! (EACCES/EROFS on systems without a video-group/udev policy) or when no
//! sysfs device exists; reads prefer sysfs whenever a node is present. The
//! backend flips to the spawn path permanently on the FIRST denied sysfs
//! write, not per event. When no backend can write the level still displays
//! but interactions no-op (`g_read_only`), and a sub whose sysfs device has
//! nothing usable renders nothing (zero-width slot).
//!
//! Device selection: auto-discovery scans `/sys/class/backlight/*` and picks
//! the lexicographically smallest device with a positive `max_brightness`.
//! The optional `brightness_device` config pin selects a specific backlight,
//! or -- with a `led:` prefix -- an LED-class device (`/sys/class/leds/*`),
//! the only route to LED-class panels so an unrelated status LED is never
//! picked up accidentally.
//!
//! The sysfs I/O helpers take an explicit `base` root ("" = the real `/`),
//! so tests can point them at a fabricated `/class/backlight/<dev>/*` tree
//! without touching the host's backlight.

const std = @import("std");
const types = @import("types");
const slider = @import("slider");
const drawing = @import("drawing");
const spawn_capture = @import("spawn_capture");

const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

/// Largest device/pin name accepted (sysfs device names are short; a longer
/// pin is ignored and auto-discovery is used instead).
const max_dev_len: usize = 64;

const default_format = "BRT {pct}%";

/// Where a filesystem pin points: the backlight class by default, or the LED
/// class when the config pin is spelled `led:<name>`.
const Backend = enum { unknown, sysfs, brightnessctl };
pub const Class = enum { backlight, leds };

/// Read/write resolution, mirroring the volume sub's auto-detection: sysfs
/// first, brightnessctl as the no-sysfs fallback, `unknown` while nothing has
/// answered (re-probed on every poll).
var g_backend: Backend = .unknown;
var g_class: Class = .backlight;
var g_dev: [max_dev_len]u8 = undefined;
var g_dev_len: usize = 0;
/// `brightness_device` pin copied from config at draw time (config slices are
/// freed on reload; we keep an owned copy so poll-time reads are safe).
var g_pin: [max_dev_len]u8 = undefined;
var g_pin_len: usize = 0;
var g_pct: u8 = 0;
var g_has_value: bool = false;
var g_read_only: bool = false;

const bt_get_cmd = "brightnessctl get";
const bt_max_cmd = "brightnessctl max";

fn classDir(class: Class) []const u8 {
    return switch (class) {
        .backlight => "backlight",
        .leds => "leds",
    };
}

/// Composes the sysfs attribute path relative to `base` ("" => the real /
/// root) into `buf`. Null when it does not fit.
fn attrPath(buf: []u8, base: []const u8, class: Class, dev: []const u8, comptime attr: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/class/{s}/{s}/{s}", .{ base, classDir(class), dev, attr }) catch null;
}

/// Reads a small unsigned integer from a sysfs text attribute.
fn readU32File(path: []const u8) ?u32 {
    const io = std.Options.debug_io;
    var buf: [32]u8 = undefined;
    const f = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer f.close(io);
    const n = f.readPositionalAll(io, &buf, 0) catch return null;
    const txt = std.mem.trim(u8, buf[0..n], " \n\r");
    return std.fmt.parseUnsigned(u32, txt, 10) catch null;
}

fn readMaxOf(base: []const u8, class: Class, dev: []const u8) ?u32 {
    var p: [std.fs.max_path_bytes]u8 = undefined;
    const path = attrPath(&p, base, class, dev, "max_brightness") orelse return null;
    return readU32File(path);
}

/// The device's current level in raw units: prefers the commit node
/// (`brightness`, the value the display follows after a write), falling back
/// to `actual_brightness` (LED-class devices expose only `brightness`).
fn readRawValue(base: []const u8, class: Class, dev: []const u8) ?u32 {
    var p: [std.fs.max_path_bytes]u8 = undefined;
    if (attrPath(&p, base, class, dev, "brightness")) |path| {
        if (readU32File(path)) |v| return v;
    }
    const path = attrPath(&p, base, class, dev, "actual_brightness") orelse return null;
    return readU32File(path);
}

/// Maps a raw level onto the 0-100 scale; null when the device is unusable
/// (max unknown or zero). The linear map itself is the shared
/// `slider.pctFromRaw` (nearest-rounding).
pub fn pctFromRaw(raw: u32, max: u32) ?u8 {
    if (max == 0) return null;
    return slider.pctFromRaw(u32, raw, 0, max);
}

/// Maps a 0-100 percent onto the device's raw scale (the shared
/// `slider.rawFromPct`, nearest-rounding).
pub fn rawFromPct(pct: u8, max: u32) u32 {
    return slider.rawFromPct(u32, pct, 0, max);
}

/// Reads the normalized 0-100 level of `dev` from the fabricated-or-real
/// class tree at `base`.
pub fn readPctFrom(base: []const u8, class: Class, dev: []const u8) ?u8 {
    if (dev.len == 0) return null;
    const max = readMaxOf(base, class, dev) orelse return null;
    if (max == 0) return null;
    const raw = readRawValue(base, class, dev) orelse return null;
    return pctFromRaw(raw, max);
}

/// Why a sysfs write did not happen. `denied` is the ONLY outcome that says
/// something about this user's authority on the node; every other failure is
/// transient and says nothing, so it must not latch the module read-only.
pub const WriteResult = enum { ok, denied, transient };

/// Maps an errno to the two failure classes. EACCES/EPERM mean the kernel
/// refused this user; anything else (ENOENT while a driver rebinds, EIO, EISDIR
/// on a file-backed lookalike, ENOSPC) is a condition that can differ on the
/// very next commit.
fn classify(err: std.posix.E) WriteResult {
    return switch (err) {
        .ACCES, .PERM => .denied,
        else => .transient,
    };
}

/// Writes `val` into a sysfs text attribute, reporting ok/denied/transient
/// on failure (missing device, permission denied, read-only mount). Raw
/// POSIX I/O: the node must be written as-is, and O_TRUNC keeps file-backed
/// lookalikes (used by tests) from keeping stale tail bytes.
fn writeU32File(path: []const u8, val: u32) WriteResult {
    var pz: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= pz.len) return .transient;
    @memcpy(pz[0..path.len], path);
    pz[path.len] = 0;
    var vbuf: [16]u8 = undefined;
    const txt = std.fmt.bufPrint(&vbuf, "{d}", .{val}) catch return .transient;
    const fd = c.open(&pz, c.O_WRONLY | c.O_TRUNC);
    if (fd < 0) return classify(std.posix.errno(-fd));
    defer _ = c.close(fd);
    var off: usize = 0;
    while (off < txt.len) {
        const n = c.write(fd, txt.ptr + off, txt.len - off);
        if (n <= 0) return classify(std.posix.errno(-n));
        off += @intCast(n);
    }
    return .ok;
}

/// Applies a normalized 0-100 level straight to the kernel's `brightness`
/// node. Returns false when the write did not happen (no device, denied).
pub fn applyPctTo(base: []const u8, class: Class, dev: []const u8, pct: u8) WriteResult {
    if (dev.len == 0) return .transient;
    const max = readMaxOf(base, class, dev) orelse return .transient;
    if (max == 0) return .transient;
    const raw = rawFromPct(slider.clampPct(pct), max);
    var p: [std.fs.max_path_bytes]u8 = undefined;
    const path = attrPath(&p, base, class, dev, "brightness") orelse return .transient;
    return writeU32File(path, raw);
}

/// Resolves which device to use into `out_dev` (returning its length) and
/// `out_class`. A non-empty `pin` names a backlight device, or an LED-class
/// device when spelled `led:<name>`; if the pin does not resolve, the scan
/// falls back to the lexicographically smallest usable `/class/backlight/*`
/// entry (deterministic regardless of readdir order). Null when nothing is
/// usable.
pub fn findDevice(base: []const u8, pin: []const u8, out_class: *Class, out_dev: []u8) ?usize {
    if (pin.len != 0) {
        var class: Class = .backlight;
        var dev: []const u8 = pin;
        if (std.mem.startsWith(u8, dev, "led:")) {
            class = .leds;
            dev = dev[4..];
        }
        if (dev.len != 0 and dev.len <= out_dev.len) {
            if (readMaxOf(base, class, dev)) |max| if (max != 0) {
                @memcpy(out_dev[0..dev.len], dev);
                out_class.* = class;
                return dev.len;
            };
        }
    }

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/class/backlight", .{base}) catch return null;
    const io = std.Options.debug_io;
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var best: [max_dev_len]u8 = undefined;
    var best_len: usize = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .directory) continue;
        if (e.name.len == 0 or e.name.len > max_dev_len) continue;
        if (e.name[0] == '.') continue;
        const max = readMaxOf(base, .backlight, e.name) orelse continue;
        if (max == 0) continue;
        if (best_len == 0 or std.mem.lessThan(u8, e.name, best[0..best_len])) {
            @memcpy(best[0..e.name.len], e.name);
            best_len = e.name.len;
        }
    }
    if (best_len == 0) return null;
    @memcpy(out_dev[0..best_len], best[0..best_len]);
    out_class.* = .backlight;
    return best_len;
}

fn discoverDevice(base: []const u8) void {
    if (findDevice(base, g_pin[0..g_pin_len], &g_class, &g_dev)) |n| {
        g_dev_len = n;
    } else {
        g_dev_len = 0;
    }
}

/// Re-reads the level from the live backend (sysfs preferred, brightnessctl
/// as the no-sysfs fallback). Returns true when this read changed the state.
fn readBrightness() bool {
    const had_value = g_has_value;
    const old_pct = g_pct;

    // Re-discover while the device is unresolved and we are not already on
    // the brightnessctl fallback (which means no sysfs device answered); the
    // scan cost is a handful of tiny file reads, once per poll.
    if (g_dev_len == 0 and g_backend != .brightnessctl) discoverDevice("");
    if (g_dev_len != 0) {
        if (readPctFrom("", g_class, g_dev[0..g_dev_len])) |p| {
            g_backend = .sysfs;
            g_pct = p;
            g_has_value = true;
            return !had_value or g_pct != old_pct;
        }
    }
    if (brightnessctlRead()) |p| {
        g_backend = .brightnessctl;
        g_pct = p;
        g_has_value = true;
        return !had_value or g_pct != old_pct;
    }
    g_backend = .unknown;
    g_dev_len = 0;
    return false;
}

/// Reads the level through `brightnessctl` when no sysfs device answers
/// (`get` + `max` both parse and max is positive).
fn brightnessctlRead() ?u8 {
    var buf: [64]u8 = undefined;
    const raw_s = spawn_capture.runOut(bt_get_cmd, &buf);
    if (std.fmt.parseUnsigned(u32, std.mem.trim(u8, raw_s, " \n\r"), 10)) |raw| {
        const max_s = spawn_capture.runOut(bt_max_cmd, &buf);
        return pctFromRaw(
            raw,
            std.fmt.parseUnsigned(u32, std.mem.trim(u8, max_s, " \n\r"), 10) catch return null,
        ) orelse null;
    } else |_| return null;
}

/// Applies a level through `brightnessctl` (the per-write fallback for
/// permission-denied sysfs nodes).
fn brightnessctlApply(pct: u8) bool {
    var buf: [64]u8 = undefined;
    const cmd = std.fmt.bufPrint(&buf, "brightnessctl set {d}%", .{slider.clampPct(pct)}) catch return false;
    return spawn_capture.runOk(cmd);
}

/// The latency class of one commit on the live backend: a direct sysfs write
/// is microseconds and needs no window, while the `brightnessctl` fallback is
/// a fork+exec that does. Named value (see `slider.CommitCost`) rather than
/// the bare bool this used to be.
fn commitCost() slider.CommitCost {
    return if (g_backend == .sysfs) .immediate else .rate_limited;
}

/// Applies a level to whatever backend can write: a direct sysfs write when
/// that backend is live (one tiny file write, un-throttled -- the common case
/// with a write policy), otherwise a `brightnessctl` spawn. `g_read_only` is
/// set only when every path fails (sysfs denied and no working
/// brightnessctl). Scheduled by the slider core's throttle, which owns the
/// commit clock.
fn commitPct(v: u8) void {
    const pct = slider.clampPct(v);
    const direct = g_backend == .sysfs;
    const wrote: WriteResult = if (direct) applyPctTo("", g_class, g_dev[0..g_dev_len], pct) else .transient;
    var ok = wrote == .ok;
    if (!ok) {
        // A usable device may still refuse the write (root-only node, no udev
        // rule): fall back to the spawn, and remember the flip so every later
        // commit spawns and stays rate-limited (once per window, not per event).
        if (brightnessctlApply(pct)) {
            if (direct) g_backend = .brightnessctl;
            ok = true;
        }
    }
    // Latch read-only ONLY on a permission denial that the fallback also could
    // not work around. The old `g_read_only = !ok` latched on ANY failure, so
    // one transient EIO -- or the brightness node briefly vanishing while a
    // driver rebound -- turned the module into a permanent, silent no-op for
    // the rest of the session, with the segment still rendering a level the
    // user could not actually change.
    g_read_only = !ok and wrote == .denied;
}

/// One-shot apply (press, drag end): commit then re-read so the display
/// follows the device immediately rather than on the next poll tick.
/// The one write entry point, replacing `previewPct` / `commitPct` /
/// `applyPct`.
///
/// The three were one function each, and the clamp and the display update were
/// written three times, so they could drift: a preview that forgot to clamp
/// showed a level the backend then refused, and an apply that forgot to
/// re-read left the label behind the device. Here the mode names the
/// difference and there is one copy of each thing that differs.
fn write(w: slider.Write, v: u8) void {
    switch (w) {
        // Scroll/drag motion: the label follows immediately, the backend write
        // is the core scheduler's business.
        .preview => g_pct = slider.clampPct(v),
        // The scheduler's commit: write, and let the next read reconcile.
        .commit => commitPct(v),
        // Press set / drag end: write, then re-read so the label follows the
        // device immediately rather than on the next poll tick.
        .apply => {
            commitPct(v);
            _ = readBrightness();
        },
    }
}

/// Renders the display string into `buf`, substituting every `{pct}`
/// placeholder, and returns the text (plus the numeric region); a truncated
/// tail is still a complete, scan-safe string.
fn renderDisplay(config: types.BarConfig, pct: u8, buf: []u8) drawing.Label {
    const fmt = config.brightness_format orelse default_format;
    return drawing.renderLineValue(fmt, pct, null, buf);
}

/// Copies the config's `brightness_device` pin into the owned buffer (config
/// string slices are freed on reload; poll-time reads need a stable copy).
fn cacheConfigPin(config: types.BarConfig) void {
    const pin = config.brightness_device orelse "";
    g_pin_len = @min(pin.len, max_dev_len);
    @memcpy(g_pin[0..g_pin_len], pin[0..g_pin_len]);
}

/// Idle label hook: the slider core renders this during the segment's draw.
/// Test-only seam: the display state `label` reads (`g_pct`) is module-private,
/// and its tests live in `src/test/bar/brightness_test.zig`, which needs this
/// to set their state: this harness runs tests from the test ROOT, so an
/// inline test in an imported module is never even ANALYZED. A plain `pub` on
/// the global would export mutable global state to every importer; this
/// scopes the write to an obviously test-shaped name.
pub fn setDisplayForTest(pct: u8) void {
    g_pct = pct;
}

pub fn label(config: types.BarConfig, buf: []u8) drawing.Label {
    cacheConfigPin(config);
    return renderDisplay(config, g_pct, buf);
}

// Current level / presence / write-gate hooks for the core.

/// The displayed level, or null while no backlight device has answered. The
/// absence and the value were a `{bool, u8}` pair latched together; they are
/// one optional now.
fn currentLevel() ?u8 {
    return if (g_has_value) g_pct else null;
}

fn writable() bool {
    return !g_read_only;
}

pub const sub: slider.Sub = .{
    .name = "brightness",
    .read_interval_ms = 1000,
    .level = currentLevel,
    .writable = writable,
    .read = readBrightness,
    .write = write,
    .commit_cost = commitCost,

    .label = label,
    .probeNaturalWidth = 44,
};
