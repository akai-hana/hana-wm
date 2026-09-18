//! Brightness bar segment.
//! Shows the display backlight level and controls it:
//!   - wheel up/down (buttons 4/5): +/- 2 %
//!   - left press / press-hold drag: set the level from the horizontal
//!     position (the whole reserved slot is the slider; x/width maps linearly
//!     to 0-100 %). While the press is held the segment renders as an
//!     accent-filled loading bar; style reverts to the label on release.
//!   - right press: reserved (brightness has no mute-style second state), so
//!     right-click is a no-op.
//! Reads happen once per 1 s poll cadence (plus an immediate first read at
//! first draw and a re-read after every apply).
//!
//! Backend: unlike the volume segment (which shells out to `pactl`/`amixer`),
//! brightness is controlled through the kernel's own sysfs interface --
//! `/sys/class/backlight/<dev>/brightness` plus `max_brightness` -- which is
//! exactly what userspace tools like `brightnessctl` wrap. Direct sysfs I/O
//! needs no tool, no udev rules, and no subprocess spawn (a commit is one
//! tiny file write, so drags need no throttle). A `brightnessctl` subprocess
//! is used only as a fallback when a direct write is denied (EACCES/EROFS on
//! systems without a video-group/udev policy) or when no sysfs device exists;
//! reads prefer sysfs whenever a node is present.
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
//!
//! When no backend can write (sysfs denied and no brightnessctl), the level
//! still displays but interactions no-op (`g_read_only`).

const std = @import("std");
const types = @import("types");
const utils = @import("utils");
const drawing = @import("drawing");
const segmod = @import("segment");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

const read_interval_ms: i64 = 1000;
const probe_natural_width: u16 = 44;
const scroll_step: u8 = 2;
/// Largest device/pin name accepted (sysfs device names are short; a longer
/// pin is ignored and auto-discovery is used instead).
const max_dev_len: usize = 64;

const default_format = "BRT {pct}%";

/// Where a filesystem pin points: the backlight class by default, or the LED
/// class when the config pin is spelled `led:<name>`.
const Backend = enum { unknown, sysfs, brightnessctl };
pub const Class = enum { backlight, leds };

/// Read/write resolution, mirroring the volume segment's auto-detection:
/// sysfs first, brightnessctl as the no-sysfs fallback, `unknown` while
/// nothing has answered (re-probed on every poll).
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
var g_armed: bool = false;
var g_next_read_ms: i64 = 0;
var g_pending_redraw: bool = false;
var g_dragging: bool = false;
/// True while a press-hold scrub is active: draw switches to the drag-mode
/// loading bar (reserved-slot width) instead of the text.
var g_read_only: bool = false;
/// Reserved slot width from the last draw; doubles as the slider denominator.
var g_slot_width: u16 = 0;
/// Scratch for the rendered display string; persists until the next draw so
/// the returned slice stays valid past the draw call.
var g_display: [128]u8 = undefined;
var g_display_len: usize = 0;

const bt_get_cmd = "brightnessctl get";
const bt_max_cmd = "brightnessctl max";

fn nowMs() i64 {
    return @intCast(utils.realtimeNs() / std.time.ns_per_ms);
}

/// Runs `cmd` via /bin/sh and returns its captured stdout, trimmed of
/// trailing whitespace. Empty slice on any failure (popen denied, the child
/// wrote nothing, or the command is too long for the fixed buffer).
fn runOut(cmd: []const u8, buf: []u8) []const u8 {
    if (cmd.len + 1 > 256) return "";
    var cmd_buf: [256]u8 = undefined;
    @memcpy(cmd_buf[0..cmd.len], cmd);
    cmd_buf[cmd.len] = 0;
    const f = c.popen(&cmd_buf, "r") orelse return "";
    defer _ = c.pclose(f);
    const n = c.fread(buf.ptr, 1, buf.len, f);
    if (n == 0) return "";
    return std.mem.trimEnd(u8, buf[0..n], " \n\r");
}

/// Runs `cmd`, drains its output (so pclose never blocks on a full pipe), and
/// returns whether the child exited 0.
fn runOk(cmd: []const u8) bool {
    if (cmd.len + 1 > 256) return false;
    var cmd_buf: [256]u8 = undefined;
    @memcpy(cmd_buf[0..cmd.len], cmd);
    cmd_buf[cmd.len] = 0;
    const f = c.popen(&cmd_buf, "r") orelse return false;
    var sink: [64]u8 = undefined;
    _ = c.fread(&sink, 1, sink.len, f);
    return c.pclose(f) == 0;
}

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
pub fn pctFromRaw(raw: u32, max: u32) ?u8 {
    if (max == 0) return null;
    const v: u64 = @as(u64, raw) * 100 / max;
    return @intCast(@min(v, 100));
}

/// Maps a 0-100 percent onto the device's raw scale (nearest rounding).
pub fn rawFromPct(pct: u8, max: u32) u32 {
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
    const raw_s = runOut(bt_get_cmd, &buf);
    if (std.fmt.parseUnsigned(u32, std.mem.trim(u8, raw_s, " \n\r"), 10)) |raw| {
        const max_s = runOut(bt_max_cmd, &buf);
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
    return runOk(cmd);
}

/// Applies a level to whatever backend can write. `g_read_only` is set only
/// when every path fails (sysfs denied and no working brightnessctl).
fn commitPct(v: u8) void {
    const pct = @min(v, 100);
    const ok = switch (g_backend) {
        .sysfs => if (applyPctTo("", g_class, g_dev[0..g_dev_len], pct))
            true
        else
            brightnessctlApply(pct),
        .brightnessctl => brightnessctlApply(pct),
        .unknown => brightnessctlApply(pct),
    };
    g_read_only = !ok;
}

/// Applies a state change, then re-reads so the display follows the device
/// immediately rather than on the next poll tick.
fn setPct(v: u8) void {
    commitPct(v);
    _ = readBrightness();
}

/// Linear slider mapping: click/drag offset across the reserved slot maps to
/// 0-100 %. The bar records the click bound at the reserved width, which this
/// module mirrors in `g_slot_width` at draw time.
pub fn pctFromOffset(offset: u16) u8 {
    const w: u32 = @max(@as(u32, g_slot_width), 1);
    const v: u32 = @as(u32, offset) * 100 / w;
    return @intCast(@min(v, 100));
}

/// Renders the display string into `g_display`, substituting every `{pct}`
/// placeholder, and returns the text. `g_display_len` is updated; a truncated
/// tail is still a complete, scan-safe string.
fn renderDisplay(config: types.BarConfig, pct: u8) []const u8 {
    const fmt = config.brightness_format orelse default_format;

    var n: usize = 0;
    var i: usize = 0;
    while (i < fmt.len and n < g_display.len) {
        if (fmt[i] == '{') {
            if (std.mem.startsWith(u8, fmt[i..], "{pct}")) {
                var b: [16]u8 = undefined;
                const ps = std.fmt.bufPrint(&b, "{d}", .{pct}) catch break;
                if (n + ps.len > g_display.len) break;
                @memcpy(g_display[n..][0..ps.len], ps);
                n += ps.len;
                i += 5;
                continue;
            }
        }
        g_display[n] = fmt[i];
        n += 1;
        i += 1;
    }
    g_display_len = n;
    return g_display[0..n];
}

/// Copies the config's `brightness_device` pin into the owned buffer (config
/// string slices are freed on reload; poll-time reads need a stable copy).
fn cacheConfigPin(config: types.BarConfig) void {
    const pin = config.brightness_device orelse "";
    g_pin_len = @min(pin.len, max_dev_len);
    @memcpy(g_pin[0..g_pin_len], pin[0..g_pin_len]);
}

/// Poll deadline: the module doesn't arm itself until its first draw (when
/// the bar actually renders it), so an unconfigured brightness segment never
/// wakes the loop. Returns -1 while unarmed, ms until the next read otherwise
/// (0 = due now).
pub fn pollDeadlineMs() i32 {
    if (!g_armed) return -1;
    const left = g_next_read_ms - nowMs();
    if (left <= 0) return 0;
    return @intCast(@min(left, read_interval_ms));
}

pub fn onPollWakeup() void {
    if (!g_armed) return;
    if (nowMs() < g_next_read_ms) return;
    g_next_read_ms = nowMs() + read_interval_ms;
    if (readBrightness()) g_pending_redraw = true;
}

pub fn consumeRedrawRequest() bool {
    const p = g_pending_redraw;
    g_pending_redraw = false;
    return p;
}

fn naturalWidthHook(_: *const anyopaque, _: u16) u16 {
    return if (g_slot_width != 0) g_slot_width else probe_natural_width;
}

/// Drag-mode loading bar: paints the whole reserved slot with a background
/// strip plus a fill (the title segment's minimized accent) proportional to
/// the level, and overlays the live percentage centered in the slot. Returns
/// the slot's far edge WITHOUT feeding `g_slot_width`: the text width must
/// survive the scrub so the drag-end redraw re-renders the label in place.
fn drawDragBar(dc: *segmod.DrawCtx, x: u16) u16 {
    const slot = if (dc.width != 0) dc.width else g_slot_width;
    const height = dc.height;
    dc.dc.fillRect(x, 0, slot, height, dc.config.bg);
    const pad = @max(@as(u16, 1), dc.config.scaledSegmentPadding(height) / 2);
    const inner_w = slot -| pad * 2;
    const inner_h = height -| pad * 2;
    const fill_w: u16 = @intCast(@as(u32, inner_w) * g_pct / 100);
    if (fill_w != 0 and inner_h != 0)
        dc.dc.fillRect(x + pad, pad, fill_w, inner_h, dc.config.title_minimized_accent);

    var b: [8]u8 = undefined;
    if (std.fmt.bufPrint(&b, "{d}", .{g_pct})) |pct| {
        const tw = dc.dc.measureTextWidth(pct);
        dc.dc.drawText(x +| slot / 2 -| tw / 2, dc.dc.baselineY(height), pct, dc.config.fg) catch {};
    } else |_| {}
    return x + slot;
}

fn drawHook(ctx: *anyopaque, x: u16) !u16 {
    const dc = segmod.castDraw(ctx);
    cacheConfigPin(dc.config);
    // First draw is the arming read: fill the segment before its poll cadence.
    if (!g_armed) {
        _ = readBrightness();
        g_armed = true;
        g_next_read_ms = nowMs() + read_interval_ms;
    }

    // No usable device anywhere: the segment contributes an empty zero-width
    // slot (nothing to show or scrub).
    if (!g_has_value) return x;

    // While scrubbed the segment is a loading bar; the label resumes on the
    // drag-end redraw.
    if (g_dragging) return drawDragBar(dc, x);

    const display = renderDisplay(dc.config, g_pct);
    const end_x = try drawing.drawPaddedSegment(dc.dc, dc.config, dc.height, x, display);

    // Track the ACTUAL painted width, not the row reservation (see the
    // volume segment's note): a width change marks the segment dirty so the
    // bar re-lays out. The slot also feeds the click bound and the slider
    // denominator.
    const drawn = end_x - x;
    if (drawn != g_slot_width) g_pending_redraw = true;
    g_slot_width = drawn;
    return end_x;
}

/// Left press: enter drag mode and set the level at the pressed position;
/// right press is reserved (no brightness analog to volume's mute) and
/// returns unhandled. Redraws inside the click so the value updates without
/// waiting for the next poll.
fn onClickHook(
    offset: u16,
    left: bool,
    right: bool,
    _: *anyopaque,
    _: *const fn (*anyopaque, u16) void,
    redraw: *const fn () void,
) bool {
    if (!g_has_value or g_read_only) return false;
    if (left) {
        g_dragging = true;
        setPct(pctFromOffset(offset));
    } else if (right) {
        return false;
    } else {
        return false;
    }
    g_pending_redraw = true;
    redraw();
    return true;
}

fn onScrollHook(dir: i8, redraw: *const fn () void) bool {
    if (!g_has_value or g_read_only) return false;
    const base: u16 = g_pct;
    const new_u: u16 = if (dir > 0)
        @min(base + scroll_step, 100)
    else
        base -| scroll_step;
    setPct(@intCast(new_u));
    g_pending_redraw = true;
    redraw();
    return true;
}

/// Press-hold scrub: sysfs commits are one tiny file write, so every motion
/// applies immediately (unlike the volume segment, no spawn throttle is
/// needed). Uses the bar's segment-scoped repaint so the display updates
/// without re-laying the whole bar.
fn onDragMotionHook(offset: u16, redraw: *const fn () void) bool {
    if (!g_has_value or g_read_only) return false;
    g_pct = pctFromOffset(offset);
    commitPct(g_pct);
    redraw();
    return true;
}

/// Scrub end (button-1 release): re-read the device so the label shows its
/// truth, and repaint back to text mode.
fn onDragEndHook(redraw: *const fn () void) void {
    if (g_dragging) {
        g_dragging = false;
        _ = readBrightness();
        g_pending_redraw = true;
        redraw();
    }
}

pub const module: @import("plugin").Segment = .{
    .name = "brightness",
    .clickable = true,
    .self_ticking = false,
    .pollTimeoutMs = pollDeadlineMs,
    .onPollWakeup = onPollWakeup,
    .consumeRedrawRequest = consumeRedrawRequest,
    .naturalWidth = naturalWidthHook,
    .draw = drawHook,
    .onClick = onClickHook,
    .onScroll = onScrollHook,
    .onDragMotion = onDragMotionHook,
    .onDragEnd = onDragEndHook,
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

test "pctFromOffset uses reserved width" {
    g_slot_width = 100;
    try testing.expectEqual(@as(u8, 0), pctFromOffset(0));
    try testing.expectEqual(@as(u8, 50), pctFromOffset(50));
    try testing.expectEqual(@as(u8, 100), pctFromOffset(100));
    try testing.expectEqual(@as(u8, 1), pctFromOffset(1));
}

test "renderDisplay honors configuration" {
    var cfg = types.BarConfig{};
    cfg.brightness_format = "Level {pct}";
    g_pct = 42;
    try testing.expectEqualStrings("Level 42", renderDisplay(cfg, g_pct));
}

test "renderDisplay default format" {
    const cfg = types.BarConfig{};
    g_pct = 33;
    try testing.expectEqualStrings("BRT 33%", renderDisplay(cfg, g_pct));
}
