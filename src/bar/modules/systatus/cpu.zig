//! Systatus CPU readout.
//! Computes aggregate core utilization % from the delta of the first
//! /proc/stat line. The very first read has no previous sample to subtract, so
//! it takes one short real measurement of its own (see `bootAverage`) and
//! reports that: the segment renders on the first frame like RAM/VOL/BRT do,
//! rather than staying collapsed for a tick.
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
    // Need at least user/nice/system/idle: below 4 fields `idle` (nums[3])
    // would come from the undefined buffer slot.
    if (count < 4) return null;
    // idle = idle + iowait (fields 4 and 5, one-based). Older kernels stop at
    // idle, hence the guard.
    const idle = if (count >= 5) nums[3] +| nums[4] else nums[3];
    var total: u64 = 0;
    for (nums[0..count]) |v| total += v;
    return .{ .total = total, .idle = idle };
}

/// Busy % between two samples, or null when the interval is not usable: a
/// zero/rewound total (a VM suspend/resume resets the kernel counters) or no
/// elapsed jiffies at all.
pub fn utilBetween(prev: Sample, cur: Sample) ?u8 {
    if (prev.total == 0 or cur.total < prev.total) return null;
    const d_total = cur.total - prev.total;
    if (d_total == 0) return 0;
    const d_idle = cur.idle -| prev.idle;
    const busy = (d_total - d_idle) * 100 / d_total;
    return @intCast(@min(busy, 100));
}

/// Busy % over the whole span the kernel has been counting, i.e. since boot.
/// This is the reading for the very first sample, which by definition has no
/// predecessor to subtract. Every later sample uses `utilBetween` and is a
/// real interval reading, so this value lives exactly one frame.
///
/// It is a genuine measurement rather than a placeholder: /proc/stat's
/// counters are cumulative from boot, so this is the true average
/// utilization over that span. It just answers a different question than every
/// later frame ("since boot" vs "since the last tick"), which is why it does
/// not recur. Null only when the kernel has counted nothing yet.
pub fn bootAverage(cur: Sample) ?u8 {
    // Computed directly rather than by handing a zeroed predecessor to
    // `utilBetween`: that helper treats `total == 0` as an unusable baseline
    // (a rewound counter), and a boot average's baseline legitimately IS zero.
    // Same arithmetic, one read, no predecessor.
    if (cur.total == 0) return null;
    const busy = cur.total -| cur.idle;
    return @intCast(@min(busy * 100 / cur.total, 100));
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

    const pct = if (cpu_prev) |prev|
        utilBetween(prev, cur)
    else
        bootAverage(cur);
    cpu_prev = cur;
    return systatus.percentSample(&g_num, pct orelse return null);
}

/// This readout's binding to the systatus surface (`systatus.Sub`): the
/// config name, the rendered label, and the readout function.
pub const sub: systatus.Sub = .{
    .name = "cpu",
    .label = "CPU",
    .read = read,
};
