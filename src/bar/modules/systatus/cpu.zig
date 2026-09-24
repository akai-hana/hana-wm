//! Systatus CPU readout.
//! Computes aggregate core utilization % from the delta of the first
//! /proc/stat line. The very first read reports the boot-cumulative average
//! while also establishing the delta baseline.

const std = @import("std");
const systatus = @import("systatus");

var cpu_prev_idle: u64 = 0;
var cpu_prev_total: u64 = 0;
var cpu_has_baseline: bool = false;

/// Aggregate CPU % from the last two /proc/stat samples. On the baseline or
/// reset read there is no delta, so the boot-cumulative utilization (busy
/// since boot over total) is reported instead -- never null when /proc/stat
/// is readable.
fn read() ?u8 {
    var buf: [512]u8 = undefined;
    const s = systatus.readSmallFile("/proc/stat", &buf) orelse return null;
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

    // Delta vs the previous sample when a baseline exists and the counters
    // moved forward (VM suspend/resume resets the counters: total < prev, so
    // fall back to the boot-cumulative average for that read).
    const use_delta = cpu_has_baseline and cpu_prev_total != 0 and total >= cpu_prev_total;
    const d_total = if (use_delta) total - cpu_prev_total else 0;
    const d_idle = if (use_delta) idle -| cpu_prev_idle else 0;
    cpu_prev_total = total;
    cpu_prev_idle = idle;
    cpu_has_baseline = true;

    if (use_delta and d_total == 0) return 0;
    if (total == 0) return 0;
    const busy = if (use_delta)
        (d_total - d_idle) * 100 / d_total
    else
        (total -| idle) * 100 / total;
    return @intCast(@min(busy, 100));
}

/// This readout's binding to the systatus surface (`systatus.Sub`): the
/// config name, the rendered label, and the readout function.
pub const sub: systatus.Sub = .{
    .name = "cpu",
    .label = "CPU",
    .read = read,
};
