//! Brightness slider sub. Shows the display backlight level and controls it,
//! bound to the slider core's `Sub` contract. This module owns the device's
//! TRUTH -- sysfs discovery, reads, writes, display format -- while the
//! slider core owns the shared render shell, interaction, poll, commit clock.
//!
//! Backend: kernel sysfs (`/sys/class/backlight/<dev>/brightness` plus
//! `max_brightness`), which is what tools like `brightnessctl` wrap. With a
//! write policy (user in `video`, the shipped udev rule) a commit is one tiny
//! file write, so drags need no throttle. A `brightnessctl` subprocess is
//! used only as a fallback when a direct write is denied (EACCES/EROFS) or
//! when no sysfs device exists; reads prefer sysfs. The backend flips to the
//! spawn path permanently on the FIRST denied write. When no backend can
//! write, the level still displays but interactions no-op (`g.read_only`).
//!
//! Device selection: auto-discovery scans `/sys/class/backlight/*` and picks
//! the lexicographically smallest device with a positive `max_brightness`.
//! The optional `brightness_device` config pin selects a specific backlight,
//! or -- with a `led:` prefix -- an LED-class device, the only route to
//! LED-class panels so a status LED is never picked up accidentally.
//!
//! The sysfs I/O helpers take an explicit `base` root ("" = the real `/`),
//! so tests can point them at a fabricated tree.

const std = @import("std");
const core = @import("core");
const types = @import("types");
const bar_config = @import("bar_config");
const slider = @import("slider");
const drawing = @import("drawing");
const spawn_capture = @import("spawn_capture");

const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

/// Largest device/pin name accepted; a longer pin is ignored and
/// auto-discovery is used instead.
const max_dev_len: usize = 64;

const default_format = "BRT {pct}%";

const Backend = enum { unknown, sysfs, brightnessctl };
pub const Class = enum { backlight, leds };

/// Consecutive total failures tolerated before the module counts itself
/// absent. Mirrors systatus': a single transient miss must not freeze the
/// readout for a whole backoff.
const miss_tolerance: u8 = 3;

/// How long an absent module goes unattempted before one more try. Without
/// this, a machine with no backlight pays a device-tree scan plus two
/// `brightnessctl` spawns every 1 s all session. With it the absent module
/// is silent but not abandoned: one slow re-probe keeps a hot-plugged panel
/// or a since-boot missing tool visible.
const absent_reprobe_ms: i64 = 30_000;

/// Owner state (P2-58): resolved backend/device, miss/backoff bookkeeping,
/// the owned pin copy, and the display value. Resolution mirrors the volume
/// sub: sysfs first, brightnessctl fallback, `unknown` while nothing has
/// answered. `misses` resets by first success; `absent_until_ms` is armed
/// when misses exhausts the tolerance. `pin` is `brightness_device` copied
/// from config (config slices are freed on reload).
const BrightnessState = struct {
    backend: Backend = .unknown,
    misses: u8 = 0,
    absent_until_ms: i64 = 0,
    class: Class = .backlight,
    dev: [max_dev_len]u8 = undefined,
    dev_len: usize = 0,
    pin: [max_dev_len]u8 = undefined,
    pin_len: usize = 0,
    pct: u8 = 0,
    has_value: bool = false,
    read_only: bool = false,
};
var g: BrightnessState = .{};

const bt_get_cmd = "brightnessctl get";
const bt_max_cmd = "brightnessctl max";

fn classDir(class: Class) []const u8 {
    return switch (class) {
        .backlight => "backlight",
        .leds => "leds",
    };
}

/// Composes the sysfs attribute path relative to `base` ("" => the real /)
/// into `buf`. Null when it does not fit.
fn attrPath(buf: []u8, base: []const u8, class: Class, dev: []const u8, comptime attr: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/class/{s}/{s}/{s}", .{ base, classDir(class), dev, attr }) catch null;
}

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

/// Maps a raw level onto the 0-100 scale; null when the device is unusable.
/// The linear map itself is the shared `slider.pctFromRaw` (nearest-rounding).
pub fn pctFromRaw(raw: u32, max: u32) ?u8 {
    if (max == 0) return null;
    return slider.pctFromRaw(u32, raw, 0, max);
}

/// Maps a 0-100 percent onto the device's raw scale (shared nearest-rounding).
pub fn rawFromPct(pct: u8, max: u32) u32 {
    return slider.rawFromPct(u32, pct, 0, max);
}

/// Reads the normalized 0-100 level of `dev` from the class tree at `base`.
pub fn readPctFrom(base: []const u8, class: Class, dev: []const u8) ?u8 {
    if (dev.len == 0) return null;
    const max = readMaxOf(base, class, dev) orelse return null;
    if (max == 0) return null;
    const raw = readRawValue(base, class, dev) orelse return null;
    return pctFromRaw(raw, max);
}

/// Why a sysfs write did not happen. `denied` is the ONLY outcome that says
/// something about this user's authority on the node; every other failure is
/// transient and must not latch the module read-only.
pub const WriteResult = enum { ok, denied, transient };

/// Maps an errno to the two failure classes. EACCES/EPERM mean the kernel
/// refused this user; anything else is a condition that can differ on the
/// very next commit.
fn classify(err: std.posix.E) WriteResult {
    return switch (err) {
        .ACCES, .PERM => .denied,
        else => .transient,
    };
}

/// Writes `val` into a sysfs text attribute, reporting ok/denied/transient.
/// Raw POSIX I/O: the node must be written as-is, and O_TRUNC keeps
/// file-backed lookalikes (used by tests) from keeping stale tail bytes.
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
/// node. Returns false when the write did not happen.
pub fn applyPctTo(base: []const u8, class: Class, dev: []const u8, pct: u8) WriteResult {
    if (dev.len == 0) return .transient;
    const max = readMaxOf(base, class, dev) orelse return .transient;
    if (max == 0) return .transient;
    const raw = rawFromPct(slider.clampPct(pct), max);
    var p: [std.fs.max_path_bytes]u8 = undefined;
    const path = attrPath(&p, base, class, dev, "brightness") orelse return .transient;
    return writeU32File(path, raw);
}

/// Resolves which device to use into `out_dev` and `out_class`. A non-empty
/// `pin` names a backlight device, or an LED-class device when spelled
/// `led:<name>`; if the pin does not resolve, the scan falls back to the
/// lexicographically smallest usable backlight entry (deterministic
/// regardless of readdir order). Null when nothing is usable.
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
    if (findDevice(base, g.pin[0..g.pin_len], &g.class, &g.dev)) |n| {
        g.dev_len = n;
    } else {
        g.dev_len = 0;
    }
}

/// Re-reads the level from the live backend (sysfs preferred, brightnessctl
/// as the no-sysfs fallback). Returns true when this read changed the state.
fn readBrightness() bool {
    const had_value = g.has_value;
    const old_pct = g.pct;

    // Absent backoff: while the last attempts total-failed past tolerance,
    // skip discovery and both fallback spawns until the slow re-probe is due.
    if (core.realtimeMs() < g.absent_until_ms) return false;

    // Re-discover while the device is unresolved and we are not already on
    // the brightnessctl fallback; the scan cost is a handful of tiny reads.
    if (g.dev_len == 0 and g.backend != .brightnessctl) discoverDevice("");
    if (g.dev_len != 0) {
        if (readPctFrom("", g.class, g.dev[0..g.dev_len])) |p| {
            g.backend = .sysfs;
            g.pct = p;
            g.has_value = true;
            noteProbe(true);
            return !had_value or g.pct != old_pct;
        }
    }
    if (brightnessctlRead()) |p| {
        g.backend = .brightnessctl;
        g.pct = p;
        g.has_value = true;
        noteProbe(true);
        return !had_value or g.pct != old_pct;
    }
    g.backend = .unknown;
    g.dev_len = 0;
    noteProbe(false);
    return false;
}

/// Miss accounting after one whole read attempt: a success resets the absent
/// window; failures arm the slow re-probe once the tolerance is exhausted, so
/// a permanently backlight-less machine settles into one try per
/// `absent_reprobe_ms` instead of a spawn per second.
fn noteProbe(ok: bool) void {
    if (ok) {
        g.misses = 0;
        g.absent_until_ms = 0;
        return;
    }
    if (g.misses < std.math.maxInt(u8)) g.misses += 1;
    if (g.misses >= miss_tolerance) g.absent_until_ms = core.realtimeMs() + absent_reprobe_ms;
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

/// The latency class of one commit: a direct sysfs write is microseconds
/// and needs no window, while the `brightnessctl` fallback is a fork+exec
/// that does (see `slider.CommitCost`).
fn commitCost() slider.CommitCost {
    return if (g.backend == .sysfs) .immediate else .rate_limited;
}

/// Applies a level to whatever backend can write: sysfs when live (one tiny
/// file write, un-throttled), otherwise a `brightnessctl` spawn. `g.read_only`
/// is set only when every path fails. Scheduled by the slider core's throttle.
fn commitPct(v: u8) void {
    const pct = slider.clampPct(v);
    const direct = g.backend == .sysfs;
    const wrote: WriteResult = if (direct) applyPctTo("", g.class, g.dev[0..g.dev_len], pct) else .transient;
    var ok = wrote == .ok;
    if (!ok) {
        // Fall back to the spawn, and remember the flip so every later
        // commit spawns and stays rate-limited (once per window, not per event).
        if (brightnessctlApply(pct)) {
            if (direct) g.backend = .brightnessctl;
            ok = true;
        }
    }
    // Latch read-only ONLY on a permission denial the fallback could not work
    // around: a transient EIO, or the brightness node briefly vanishing while
    // a driver rebounds, must not turn the module into a permanent silent
    // no-op while the segment still renders a level the user cannot change.
    g.read_only = !ok and wrote == .denied;
}

/// One-shot apply (press, drag end): commit then re-read so the display
/// follows the device immediately. The single write entry point: each mode
/// names its difference, so there is one copy of the clamp and one of the
/// display update, and they cannot drift.
fn write(w: slider.Write, v: u8) void {
    switch (w) {
        // Scroll/drag motion: the label follows immediately, the backend
        // write is the core scheduler's business.
        .preview => g.pct = slider.clampPct(v),
        .commit => commitPct(v),
        .apply => {
            commitPct(v);
            _ = readBrightness();
        },
    }
}

/// Renders the display string into `buf`, substituting every `{pct}`
/// placeholder; a truncated tail is still a complete, scan-safe string.
fn renderDisplay(config: bar_config.Config, pct: u8, buf: []u8) drawing.Label {
    const fmt = config.brightness_format orelse default_format;
    return drawing.renderLineValue(fmt, pct, null, buf);
}

/// Copies the config's `brightness_device` pin into the owned buffer (config
/// slices are freed on reload). A pin change also drops the absent backoff: a
/// reload naming a different device must be probed immediately.
fn cacheConfigPin(config: bar_config.Config) void {
    const pin = config.brightness_device orelse "";
    const new_len = @min(pin.len, max_dev_len);
    const changed = g.pin_len != new_len or !std.mem.eql(u8, g.pin[0..g.pin_len], pin[0..new_len]);
    g.pin_len = new_len;
    @memcpy(g.pin[0..g.pin_len], pin[0..g.pin_len]);
    if (changed) {
        g.misses = 0;
        g.absent_until_ms = 0;
    }
}

/// Idle label hook: the slider core renders this during the segment's draw.
/// Test-only seam: the display state `label` reads is module-private, and its
/// tests live in `src/test/bar/brightness_test.zig`, which needs this to set
/// their state: this harness runs tests from the test ROOT, so an inline test
/// in an imported module is never even ANALYZED. A plain `pub` on the global
/// would export mutable state to every importer; this scopes the write to an
/// obviously test-shaped name.
pub fn setDisplayForTest(pct: u8) void {
    g.pct = pct;
}

pub fn label(config: bar_config.Config, buf: []u8) drawing.Label {
    cacheConfigPin(config);
    return renderDisplay(config, g.pct, buf);
}

// Current level / presence / write-gate hooks for the core.

/// The displayed level, or null while no backlight device has answered.
fn currentLevel() ?u8 {
    return if (g.has_value) g.pct else null;
}

fn writable() bool {
    return !g.read_only;
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
