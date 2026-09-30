//! Systatus CPU readout.
//! Computes aggregate core utilization % from the delta of the first
//! /proc/stat line. The very first read has no delta to report, so it reports
//! nothing and the arm frame stays collapsed until the second sample.

const std = @import("std");
const systatus = @import("systatus");

/// One aggregate-CPU sample: total jiffies and idle (idle+iowait) jiffies.
pub const Sample = struct { total: u64, idle: u64 };

/// Parses the leading aggregate "cpu " line of /proc/stat into a sample. Pure,
/// so the field order and the idle/iowait pairing are testable without a live
/// /proc. Null when the line is missing or malformed.
pub fn parseCpuLine(s: []const u8) ?Sample {
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
    return .{ .total = total, .idle = idle };
}

/// Busy % between two samples, or null when the interval is not usable: no
/// previous sample, a zero/rewound total (a VM suspend/resume resets the
/// kernel counters), or no elapsed jiffies at all.
///
/// Null -- not the boot-cumulative average -- is the honest answer for "no
/// interval": since-boot utilization is not the user's CPU load, and painting
/// it produced a one-frame "CPU 4%" that the very next read replaced with the
/// real number. The sticky last-good window in systatus.zig is what keeps the
/// previous reading on screen across such a gap.
pub fn utilBetween(prev: ?Sample, cur: Sample) ?u8 {
    const p = prev orelse return null;
    if (p.total == 0 or cur.total < p.total) return null;
    const d_total = cur.total - p.total;
    if (d_total == 0) return 0;
    const d_idle = cur.idle -| p.idle;
    const busy = (d_total - d_idle) * 100 / d_total;
    return @intCast(@min(busy, 100));
}

var cpu_prev: ?Sample = null;

var g_num: [16]u8 = undefined;

fn read() ?systatus.Sample {
    var buf: [512]u8 = undefined;
    const r = systatus.readFileChecked("/proc/stat", &buf) orelse return null;
    if (r.truncated) return null; // a partial /proc/stat cannot be summed
    const cur = parseCpuLine(r.bytes) orelse return null;
    const prev = cpu_prev;
    cpu_prev = cur;
    const pct = utilBetween(prev, cur) orelse return null;
    return systatus.percentSample(&g_num, pct);
}

/// This readout's binding to the systatus surface (`systatus.Sub`): the
/// config name, the rendered label, and the readout function.
pub const sub: systatus.Sub = .{
    .name = "cpu",
    .label = "CPU",
    .read = read,
};
