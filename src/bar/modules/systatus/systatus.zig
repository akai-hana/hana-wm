//! Systatus bar segment.
//! Aggregates configured system-status readouts from /proc and /sys, refreshed
//! on a 2 s poll. Each readout is a drop-in sub-segment module in this
//! directory bound to the `Sub` surface contract below.
//!
//! Rendering follows `[bar] systatus_items`:
//!   - key absent  -> default set: every `present` readout, in registry order
//!   - empty array -> NONE: the segment renders nothing
//!   - item array  -> exactly those readouts (by `name`), in the given render
//!                    order; unknown entries and duplicates are skipped
//!
//! All reads are plain file reads on the main thread -- no subprocesses, no
//! allocation -- so the 2 s cadence is effectively free.

const std = @import("std");
const types = @import("types");
const utils = @import("utils");
const drawing = @import("drawing");
const segmod = @import("segment");
const core = @import("core");

const read_interval_ms: i64 = 2000;
const probe_natural_width: u16 = 80;

// ---------------------------------------------------------------------------
// The systatus surface is a closed-core / open-module system, like every
// surface interface in this tree:
//
//   - The CLOSED CORE is this file: the `Sub` contract plus the generic
//     config/poll/render loop below. It never names a readout module; every
//     readout is reached through the `subs` registry, which is a generated
//     array (see build.zig's `buildSubsRegistryModule`).
//
//   - The OPEN MODULES are the sibling `.zig` files in this directory. Each
//     binds `pub const sub: Sub`, and membership in `subs` comes from FILE
//     PRESENCE alone: build.zig scans this dir and regenerates `systatus_subs`
//     on every build. Adding a readout = drop a file; deleting one = delete
//     the file. No source edit in the core, and no dead reference lingers
//     after a readout is removed.
//
// To add a readout: drop `foo.zig` beside this file exporting
// `pub const sub: Sub`. Every file here besides systatus.zig must export it.
// ---------------------------------------------------------------------------

pub const Sub = struct {
    /// Config identity ("mem", "cpu", ...): the name `[bar] systatus_items`
    /// entries select this readout by.
    name: []const u8,
    /// Label prefix rendered before the value ("Mem", "Cpu", ...).
    label: []const u8,
    /// Current readout as a 0-100 percent, or null when unreadable / not
    /// present this tick (the item is then skipped in the rendered row).
    read: *const fn () ?u8,
    /// Presence probe used ONLY by the default item list (absent = always
    /// present). An explicitly configured item is still rendered whenever
    /// `read` reports a value, so presence is purely a default-set filter.
    present: ?*const fn () bool = null,
};

/// The readout registry, generated from file presence (build.zig). Default
/// render order == the registry's deterministic alphabetical order.
pub const subs = @import("systatus_subs").subs;

var g_armed: bool = false;
var g_pending_redraw: bool = false;
var g_next_read_ms: i64 = 0;
var g_slot_width: u16 = 0;
/// Cached rendered text and its length; a redraw is only requested when this
/// actually changes, so the 2 s poll doesn't repaint the bar unconditionally.
var g_last: [128]u8 = undefined;
var g_len: usize = 0;

fn nowMs() i64 {
    return @intCast(utils.realtimeNs() / std.time.ns_per_ms);
}

/// Resolves the configured readout selection into `out` (a registry-index
/// array, in render order) and returns its length. Config absent = the
/// default set filtered by each readout's presence probe; an explicit list
/// is honored verbatim with unknown names and duplicates skipped. Public so
/// the registry-agnostic unit tests in `src/test/bar/systatus_test.zig` can
/// pin the semantics down (see also renderResolved in drawing.cairo).
pub fn resolveSubs(config: types.BarConfig, out: *[subs.len]usize) usize {
    var len: usize = 0;
    if (config.systatus_items) |items| {
        for (items.items) |name| {
            for (subs, 0..) |sub, i| {
                if (!std.mem.eql(u8, sub.name, name)) continue;
                var dup = false;
                for (out.*[0..len]) |existing| {
                    if (existing == i) dup = true;
                }
                if (!dup) {
                    out.*[len] = i;
                    len += 1;
                }
                break;
            }
        }
    } else {
        for (subs, 0..) |sub, i| {
            const present = if (sub.present) |p| p() else true;
            if (present) {
                out.*[len] = i;
                len += 1;
            }
        }
    }
    return len;
}

fn appendText(dst: []u8, start: usize, text: []const u8) usize {
    if (start >= dst.len) return start;
    const n = @min(dst.len - start, text.len);
    @memcpy(dst[start..][0..n], text[0..n]);
    return start + n;
}

/// Re-reads every configured readout and renders "<label> <pct>%" items in
/// order, joined with a single space, into `g_last`. Reads that fail this
/// tick (no battery, mid-baseline CPU, unreadable file) are skipped. Returns
/// true when the rendered text changed.
fn refresh() bool {
    const config = core.getState().config.bar;
    var selected: [subs.len]usize = undefined;
    const selected_len = resolveSubs(config, &selected);

    var buf: [128]u8 = undefined;
    var n: usize = 0;
    for (selected[0..selected_len]) |idx| {
        const sub = subs[idx];
        const value = sub.read();
        if (value == null) continue;
        var num: [16]u8 = undefined;
        const value_text = std.fmt.bufPrint(&num, "{d}%", .{value.?}) catch continue;
        if (n != 0) {
            if (n >= buf.len) break;
            buf[n] = ' ';
            n += 1;
        }
        n = appendText(&buf, n, sub.label);
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
/// the bar actually renders it), so an unconfigured systatus segment never
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
    .name = "systatus",
    .clickable = false,
    .self_ticking = false,
    .pollTimeoutMs = pollDeadlineMs,
    .onPollWakeup = onPollWakeup,
    .consumeRedrawRequest = consumeRedrawRequest,
    .naturalWidth = naturalWidthHook,
    .draw = drawHook,
};
