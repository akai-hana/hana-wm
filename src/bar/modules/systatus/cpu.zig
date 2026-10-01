//! Systatus CPU readout.
//! Computes aggregate core utilization % from the delta of the first
//! /proc/stat line. The very first read has no delta to report, so it reports
//! nothing and the arm frame stays collapsed until the second sample.
//!
//! Only that first line is read, and it is read into a buffer sized for a line.
//! That is the whole reason the segment used to be permanently blank:
//! /proc/stat carries one line per logical CPU (3.1 KiB on 16 cores, ~25 KiB on
//! 128), so any buffer smaller than the file reads back "truncated", and this
//! readout used to reject truncation outright -- returning null on every tick,
//! forever. Sizing for the line and accepting a short read that still contains
//! the whole line (see `aggregateLineComplete`) is what makes the buffer size a
//! detail instead of a core-count cliff.

const std = @import("std");
const systatus = @import("systatus");

/// One aggregate-CPU sample: total jiffies and idle (idle+iowait) jiffies.
pub const Sample = struct { total: u64, idle: u64 };

/// Parses the leading aggregate "cpu " line of /proc/stat into a sample. Pure,
/// so the field order and the idle/iowait pairing are testable without a live
/// /proc. Null when the line is missing or malformed.
pub fn parseCpuLine(s: []const u8) ?Sample {
    if (!std.mem.startsWith(u8, s, "cpu ")) return null;

    // ONLY the leading aggregate line, and only the part of the input up to
    // its newline. Two reasons, both load-bearing:
    //
    //  - /proc/stat continues with one line PER logical CPU ("cpu0", "cpu1",
    //    ...), so tokenizing the whole buffer walks off the aggregate line
    //    into those. `tokenizeAny` splits on the newline too, so a kernel
    //    reporting fewer aggregate counters than the array holds reached
    //    "cpu0" and failed the whole parse on a non-numeric token -- the
    //    readout silently vanished.
    //  - The field count is not fixed: kernels report user nice system idle
    //    iowait irq softirq steal and MAY add guest/guest_nice (10 here). A
    //    fixed array silently DROPPED the tail, so `total` under-counted and
    //    every derived percentage was computed against the wrong denominator.
    const line = s[0 .. std.mem.indexOfScalar(u8, s, '\n') orelse s.len];

    var nums: [16]u64 = undefined;
    var count: usize = 0;
    var toks = std.mem.tokenizeAny(u8, line, " \t\r");
    _ = toks.next() orelse return null; // "cpu"
    while (toks.next()) |tok| : (count += 1) {
        if (count >= nums.len) break;
        nums[count] = std.fmt.parseUnsigned(u64, tok, 10) catch return null;
    }
    if (count == 0) return null;
    // idle = idle + iowait (fields 4 and 5, one-based). Older kernels stop at
    // idle, hence the guard.
    const idle = if (count >= 5) nums[3] +| nums[4] else nums[3];
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

/// Whether a short read still yielded a whole aggregate line. PURE, so the
/// "truncated is fine here, truncated *inside line 1* is not" rule is
/// testable without a live multi-core /proc.
///
/// Only the leading aggregate line is needed, so the per-CPU lines past it
/// are safe to lose. What must NOT be accepted is a read that stopped INSIDE
/// the aggregate line: that parses as a smaller total and silently yields a
/// wrong delta. A newline inside the buffer proves line 1 is whole.
pub fn aggregateLineComplete(bytes: []const u8, truncated: bool) bool {
    if (!truncated) return true;
    return std.mem.indexOfScalar(u8, bytes, '\n') != null;
}

fn read() ?systatus.Sample {
    // Sized for the aggregate LINE, not for the file: see the module note on
    // why a short read is expected here rather than an I/O failure.
    var buf: [512]u8 = undefined;
    const r = systatus.readFileChecked("/proc/stat", &buf) orelse return null;
    if (!aggregateLineComplete(r.bytes, r.truncated)) return null;
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
