//! System-status bar segment.
//! Shows configured readouts from /proc and /sys, refreshed on a 2 s poll:
//!   - "mem":   used memory % (MemTotal vs MemAvailable from /proc/meminfo)
//!   - "cpu":   aggregate core utilization % (delta of the first /proc/stat
//!              line; the first read only establishes the baseline)
//!   - "batt":  charge % of the first /sys/class/power_supply/BAT* found,
//!              shown only while at least one battery is present
//! Item order follows `[bar] status_items`; when the array is empty the
//! default is mem + batt (if present) + cpu. All reads are plain file reads on
//! the main thread -- no subprocesses, no allocation -- so the 2 s cadence is
//! effectively free.

const std = @import("std");
const types = @import("types");
const utils = @import("utils");
const drawing = @import("drawing");
const segmod = @import("segment");
const core = @import("core");

const read_interval_ms: i64 = 2000;
const probe_natural_width: u16 = 80;

const Cap = enum { mem, cpu, batt };

var g_armed: bool = false;
var g_pending_redraw: bool = false;
var g_next_read_ms: i64 = 0;
var g_slot_width: u16 = 0;
/// Cached rendered text and its length; a redraw is only requested when this
/// actually changes, so the 2 s poll doesn't repaint the bar unconditionally.
var g_last: [128]u8 = undefined;
var g_len: usize = 0;

// CPU delta state: the first read only records the baseline, so the segment
// starts without a CPU readout and gains one on the first poll.
var cpu_prev_idle: u64 = 0;
var cpu_prev_total: u64 = 0;
var cpu_has_baseline: bool = false;

fn nowMs() i64 {
    return @intCast(utils.realtimeNs() / std.time.ns_per_ms);
}

fn parseMemField(s: []const u8, key: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, s, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, key)) continue;
        var toks = std.mem.tokenizeAny(u8, line, " ");
        _ = toks.next() orelse continue;
        const v = toks.next() orelse continue;
        return std.fmt.parseUnsigned(u64, v, 10) catch continue;
    }
    return null;
}

/// Used memory %: 100 * (total - available) / total. Null when meminfo is
/// unreadable.
fn memPercent() ?u8 {
    const io = std.Options.debug_io;
    var f = std.Io.Dir.openFileAbsolute(io, "/proc/meminfo", .{}) catch return null;
    defer f.close(io);
    var buf: [4096]u8 = undefined;
    const n = f.readPositionalAll(io, &buf, 0) catch return null;
    const total = parseMemField(buf[0..n], "MemTotal:") orelse return null;
    const avail = parseMemField(buf[0..n], "MemAvailable:") orelse return null;
    if (total == 0) return null;
    const used = total -| avail;
    return @intCast(@min((used * 100) / total, 100));
}

/// Aggregate CPU % from the last two /proc/stat samples. Null until a
/// baseline exists.
fn cpuPercent() ?u8 {
    const io = std.Options.debug_io;
    var f = std.Io.Dir.openFileAbsolute(io, "/proc/stat", .{}) catch return null;
    defer f.close(io);
    var buf: [512]u8 = undefined;
    const n = f.readPositionalAll(io, &buf, 0) catch return null;
    const s = buf[0..n];
    if (!std.mem.startsWith(u8, s, "cpu ")) return null;

    var nums: [8]u64 = undefined;
    var count: usize = 0;
    var toks = std.mem.tokenizeAny(u8, s, " \n");
    _ = toks.next() orelse return null; // "cpu"
    while (toks.next()) |tok| : (count += 1) {
        if (count >= nums.len) break;
        nums[count] = std.fmt.parseUnsigned(u64, tok, 10) catch return null;
    }
    if (count == 0) return null;
    const idle = if (count >= 5) nums[3] + nums[4] else nums[3];
    var total: u64 = 0;
    for (nums[0..count]) |v| total += v;

    if (!cpu_has_baseline or cpu_prev_total == 0 or total < cpu_prev_total) {
        cpu_prev_total = total;
        cpu_prev_idle = idle;
        cpu_has_baseline = true;
        return null;
    }
    const d_total = total - cpu_prev_total;
    const d_idle = idle -| cpu_prev_idle;
    cpu_prev_total = total;
    cpu_prev_idle = idle;
    if (d_total == 0) return 0;
    const busy = (d_total - d_idle) * 100 / d_total;
    return @intCast(@min(busy, 100));
}

/// Whether a battery is present at all (drives the default item list).
fn batteryPresent() bool {
    const io = std.Options.debug_io;
    var buf: [64]u8 = undefined;
    for (0..8) |i| {
        const name = std.fmt.bufPrint(&buf, "BAT{d}", .{i}) catch return false;
        var p: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&p, "/sys/class/power_supply/{s}", .{name}) catch return false;
        const dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch continue;
        dir.close(io);
        return true;
    }
    return false;
}

/// Charge % of the first present battery under /sys/class/power_supply.
fn batteryPercent() ?u8 {
    const io = std.Options.debug_io;
    var buf: [128]u8 = undefined;
    for (0..8) |i| {
        const name = std.fmt.bufPrint(&buf, "BAT{d}", .{i}) catch return null;
        var cap_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrint(&cap_buf, "/sys/class/power_supply/{s}/capacity", .{name}) catch return null;
        const f = std.Io.Dir.openFileAbsolute(io, path, .{}) catch continue;
        defer f.close(io);
        var cb: [16]u8 = undefined;
        const en = f.readPositionalAll(io, &cb, 0) catch continue;
        return std.fmt.parseUnsigned(u8, std.mem.trim(u8, cb[0..en], " \n"), 10) catch continue;
    }
    return null;
}

/// Item order: config list verbatim when non-empty (unknown/duplicate entries
/// skipped), else the capability default with the battery inserted only when
/// present.
fn decodedCaps(config: types.BarConfig, has_batt: bool, out: *[3]Cap) usize {
    var len: usize = 0;
    if (config.status_items.items.len != 0) {
        for (config.status_items.items) |name| {
            const cap: ?Cap = if (std.mem.eql(u8, name, "mem"))
                .mem
            else if (std.mem.eql(u8, name, "cpu"))
                .cpu
            else if (std.mem.eql(u8, name, "batt"))
                .batt
            else
                null;
            if (cap) |c| {
                var dup = false;
                for (out.*[0..len]) |existing| {
                    if (existing == c) dup = true;
                }
                if (!dup) {
                    out.*[len] = c;
                    len += 1;
                }
            }
        }
    } else {
        out.*[len] = .mem;
        len += 1;
        if (has_batt) {
            out.*[len] = .batt;
            len += 1;
        }
        out.*[len] = .cpu;
        len += 1;
    }
    return len;
}

fn appendText(dst: []u8, start: usize, text: []const u8) usize {
    if (start >= dst.len) return start;
    const n = @min(dst.len - start, text.len);
    @memcpy(dst[start..][0..n], text[0..n]);
    return start + n;
}

/// Re-reads every configured readout and renders "Mem 42%" / "Cpu 12%" /
/// "Batt 87%" items in order, joined with a single space, into `g_last`.
/// Reads that fail this tick (no battery, mid-baseline CPU) are skipped.
/// Returns true when the rendered text changed.
fn refresh() bool {
    const config = core.getState().config.bar;
    const has_batt = batteryPresent();
    var caps: [3]Cap = undefined;
    const caps_len = decodedCaps(config, has_batt, &caps);
    const mem = memPercent();
    const cpu = cpuPercent();
    const batt: ?u8 = if (has_batt) batteryPercent() else null;

    var buf: [128]u8 = undefined;
    var n: usize = 0;
    for (caps[0..caps_len]) |cap| {
        const value: ?u8 = switch (cap) {
            .mem => mem,
            .cpu => cpu,
            .batt => batt,
        };
        if (value == null) continue;
        var num: [16]u8 = undefined;
        const value_text = std.fmt.bufPrint(&num, "{d}%", .{value.?}) catch continue;
        const label: []const u8 = switch (cap) {
            .mem => "Mem",
            .cpu => "Cpu",
            .batt => "Batt",
        };
        if (n != 0) {
            if (n >= buf.len) break;
            buf[n] = ' ';
            n += 1;
        }
        n = appendText(&buf, n, label);
        n = appendText(&buf, n, " ");
        n = appendText(&buf, n, value_text);
        if (n >= buf.len) break;
    }

    const changed = g_len != n or !std.mem.eql(u8, g_last[0..n], buf[0..n]);
    @memcpy(g_last[0..n], buf[0..n]);
    g_len = n;
    return changed;
}

/// Poll deadline: the segment doesn't arm itself until its first draw (when
/// the bar actually renders it), so an unconfigured status segment never
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
    if (refresh()) g_pending_redraw = true;
}

pub fn consumeRedrawRequest() bool {
    const p = g_pending_redraw;
    g_pending_redraw = false;
    return p;
}

fn naturalWidthHook(_: *const anyopaque, _: u16) u16 {
    return if (g_slot_width != 0) g_slot_width else probe_natural_width;
}

fn drawHook(ctx: *anyopaque, x: u16) !u16 {
    const c = segmod.castDraw(ctx);
    if (!g_armed) {
        g_armed = true;
        g_next_read_ms = nowMs() + read_interval_ms;
        _ = refresh(); // prime the text so the first draw isn't empty
    }

    const end_x = try drawing.drawPaddedSegment(c.dc, c.config, c.height, x, g_last[0..g_len]);

    // Track the ACTUAL painted width, not the row reservation: the row must
    // follow the text or the segment locks onto the startup probe and paints
    // over its right neighbors ("Mem 42%" clipped by the next slot). A width
    // change marks the segment dirty so the bar re-lays out.
    const drawn = end_x - x;
    if (drawn != g_slot_width) g_pending_redraw = true;
    g_slot_width = drawn;
    return end_x;
}

pub const module: @import("plugin").Segment = .{
    .name = "status",
    .clickable = false,
    .self_ticking = false,
    .pollTimeoutMs = pollDeadlineMs,
    .onPollWakeup = onPollWakeup,
    .consumeRedrawRequest = consumeRedrawRequest,
    .naturalWidth = naturalWidthHook,
    .draw = drawHook,
};

const testing = std.testing;

test "parseMemField extracts the value" {
    const s = "MemTotal:       16299896 kB\nMemAvailable:    12345678 kB\nMemFree:          111 kB\n";
    try testing.expectEqual(@as(?u64, 16299896), parseMemField(s, "MemTotal:"));
    try testing.expectEqual(@as(?u64, 12345678), parseMemField(s, "MemAvailable:"));
    try testing.expectEqual(@as(?u64, null), parseMemField(s, "SwapTotal:"));
}

test "decodedCaps default and config ordering" {
    var caps: [3]Cap = undefined;
    // Default: mem, batt (present), cpu.
    var len = decodedCaps(.{}, true, &caps);
    try testing.expectEqual(@as(usize, 3), len);
    try testing.expectEqual(Cap.mem, caps[0]);
    try testing.expectEqual(Cap.batt, caps[1]);
    try testing.expectEqual(Cap.cpu, caps[2]);
    // Default without a battery: mem, cpu.
    len = decodedCaps(.{}, false, &caps);
    try testing.expectEqual(@as(usize, 2), len);
    try testing.expectEqual(Cap.mem, caps[0]);
    try testing.expectEqual(Cap.cpu, caps[1]);
    // Config list is honored verbatim, unknowns and duplicates deduplicated.
    var cfg = types.BarConfig{};
    defer cfg.status_items.deinit(testing.allocator);
    try cfg.status_items.append(testing.allocator, "cpu");
    try cfg.status_items.append(testing.allocator, "batt");
    try cfg.status_items.append(testing.allocator, "nope");
    try cfg.status_items.append(testing.allocator, "cpu");
    len = decodedCaps(cfg, false, &caps);
    try testing.expectEqual(@as(usize, 2), len);
    try testing.expectEqual(Cap.cpu, caps[0]);
    try testing.expectEqual(Cap.batt, caps[1]);
}
