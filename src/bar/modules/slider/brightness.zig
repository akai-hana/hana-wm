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
/// (max unknown or zero).
fn pctFromRaw(raw: u32, max: u32) ?u8 {
    if (max == 0) return null;
    const v: u64 = @as(u64, raw) * 100 / max;
    return @intCast(@min(v, 100));
}

/// Maps a 0-100 percent onto the device's raw scale (nearest rounding).
fn rawFromPct(pct: u8, max: u32) u32 {
    const v: u64 = (@as(u64, pct) * max + 50) / 100;
    return @intCast(@min(v, max));
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

/// Writes `val` into a sysfs text attribute. Returns false on any failure
/// (missing device, permission denied, read-only mount). Raw POSIX I/O: the
/// node must be written as-is, and O_TRUNC keeps file-backed lookalikes
/// (used by tests) from keeping stale tail bytes.
fn writeU32File(path: []const u8, val: u32) bool {
    var pz: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= pz.len) return false;
    @memcpy(pz[0..path.len], path);
    pz[path.len] = 0;
    var vbuf: [16]u8 = undefined;
    const txt = std.fmt.bufPrint(&vbuf, "{d}", .{val}) catch return false;
    const fd = c.open(&pz, c.O_WRONLY | c.O_TRUNC);
    if (fd < 0) return false;
    defer _ = c.close(fd);
    var off: usize = 0;
    while (off < txt.len) {
        const n = c.write(fd, txt.ptr + off, txt.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

/// Applies a normalized 0-100 level straight to the kernel's `brightness`
/// node. Returns false when the write did not happen (no device, denied).
pub fn applyPctTo(base: []const u8, class: Class, dev: []const u8, pct: u8) bool {
    if (dev.len == 0) return false;
    const max = readMaxOf(base, class, dev) orelse return false;
    if (max == 0) return false;
    const raw = rawFromPct(@min(pct, 100), max);
    var p: [std.fs.max_path_bytes]u8 = undefined;
    const path = attrPath(&p, base, class, dev, "brightness") orelse return false;
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
    const raw_s = slider.runOut(bt_get_cmd, &buf);
    if (std.fmt.parseUnsigned(u32, std.mem.trim(u8, raw_s, " \n\r"), 10)) |raw| {
        const max_s = slider.runOut(bt_max_cmd, &buf);
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
    const cmd = std.fmt.bufPrint(&buf, "brightnessctl set {d}%", .{@min(pct, 100)}) catch return false;
    return slider.runOk(cmd);
}

/// True when the current backend commits with a single native sysfs write
/// (microseconds, no subprocess) -- the case that needs no throttling.
fn commitIsNative() bool {
    return g_backend == .sysfs;
}

/// Applies a level to whatever backend can write: a direct sysfs write when
/// that backend is live (one tiny file write, un-throttled -- the common case
/// with a write policy), otherwise a `brightnessctl` spawn. `g_read_only` is
/// set only when every path fails (sysfs denied and no working
/// brightnessctl). Scheduled by the slider core's throttle, which owns the
/// commit clock.
fn commitPct(v: u8) void {
    const pct = @min(v, 100);
    const direct = g_backend == .sysfs;
    // A usable device may still deny the write (root-only node, no udev
    // rule): fall back to the spawn, and remember the flip so every later
    // commit spawns and stays rate-limited (once per window, not per event).
    const ok = if (direct and applyPctTo("", g_class, g_dev[0..g_dev_len], pct))
        true
    else if (brightnessctlApply(pct)) blk: {
        if (direct) g_backend = .brightnessctl;
        break :blk true;
    } else false;
    g_read_only = !ok;
}

const level = slider.Level{ .pct = &g_pct, .commit = commitPct, .reread = readBrightness };

/// One-shot apply (press, drag end): commit then re-read so the display
/// follows the device immediately rather than on the next poll tick.
fn applyPct(v: u8) void {
    level.apply(v);
}

/// Optimistic display update from a scroll/drag motion: the label follows
/// immediately while the backend write is committed by the core's scheduler.
fn previewPct(v: u8) void {
    level.preview(v);
}

/// Renders the display string into `buf`, substituting every `{pct}`
/// placeholder, and returns the text (plus the numeric region); a truncated
/// tail is still a complete, scan-safe string.
fn renderDisplay(config: types.BarConfig, pct: u8, buf: []u8) slider.Label {
    const fmt = config.brightness_format orelse default_format;
    return slider.renderLineValue(fmt, pct, null, buf);
}

/// Copies the config's `brightness_device` pin into the owned buffer (config
/// string slices are freed on reload; poll-time reads need a stable copy).
fn cacheConfigPin(config: types.BarConfig) void {
    const pin = config.brightness_device orelse "";
    g_pin_len = @min(pin.len, max_dev_len);
    @memcpy(g_pin[0..g_pin_len], pin[0..g_pin_len]);
}

/// Idle label hook: the slider core renders this during the segment's draw.
fn label(config: types.BarConfig, buf: []u8) slider.Label {
    cacheConfigPin(config);
    return renderDisplay(config, g_pct, buf);
}

// Current level / presence / write-gate hooks for the core.
fn currentPct() u8 {
    return level.current();
}

fn hasValue() bool {
    return g_has_value;
}

fn writable() bool {
    return !g_read_only;
}

pub const sub: slider.Sub = .{
    .name = "brightness",
    .read_interval_ms = 1000,
    .has_value = hasValue,
    .writable = writable,
    .read = readBrightness,
    .pct = currentPct,
    .preview = previewPct,
    .commit_is_native = commitIsNative,
    .commit = commitPct,
    .apply = applyPct,
    .label = label,
    .probeNaturalWidth = 44,
};

// Tests exercise the pure, sysfs-free geometry, scaling, and formatting
// helpers. The file-backed read/write round trips live in the dedicated
// brightness_test module, which fabricates a sysfs tree in a temp dir.
const testing = std.testing;

test "pctFromRaw maps raw onto the 0-100 scale" {
    try testing.expectEqual(@as(?u8, 75), pctFromRaw(49151, 65535));
    try testing.expectEqual(@as(?u8, 0), pctFromRaw(0, 100));
    try testing.expectEqual(@as(?u8, 100), pctFromRaw(100, 100));
    try testing.expectEqual(@as(?u8, null), pctFromRaw(50, 0));
}

test "rawFromPct maps percent back onto the raw scale" {
    try testing.expectEqual(@as(u32, 65535), rawFromPct(100, 65535));
    try testing.expectEqual(@as(u32, 0), rawFromPct(0, 65535));
    try testing.expectEqual(@as(u32, 32768), rawFromPct(50, 65535));
    try testing.expectEqual(@as(u32, 15), rawFromPct(100, 15));
    try testing.expectEqual(@as(u32, 0), rawFromPct(1, 15));
}

test "rawFromPct round-trips through pctFromRaw" {
    try testing.expectEqual(@as(?u8, 50), pctFromRaw(rawFromPct(50, 255), 255));
    try testing.expectEqual(@as(?u8, 24), pctFromRaw(rawFromPct(24, 1000), 1000));
}

test "label honors configuration" {
    var cfg = types.BarConfig{};
    cfg.brightness_format = "Level {pct}";
    var buf: [128]u8 = undefined;
    g_pct = 42;
    try testing.expectEqualStrings("Level 42", label(&cfg, &buf).text);
    try testing.expectEqualStrings("42", label(&cfg, &buf).value.?);
}

test "label default format" {
    var buf: [128]u8 = undefined;
    g_pct = 33;
    try testing.expectEqualStrings("BRT 33%", label(&(types.BarConfig{}), &buf).text);
    try testing.expectEqualStrings("33%", label(&(types.BarConfig{}), &buf).value.?);
}
