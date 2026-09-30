//! Systatus memory readout.
//! Computes used memory % from MemTotal vs MemAvailable in /proc/meminfo.
//! Null when meminfo is unreadable; the segment then simply skips this item.

const std = @import("std");
const systatus = @import("systatus");

pub fn parseRamField(s: []const u8, key: []const u8) ?u64 {
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

/// Used memory %: 100 * (total - available) / total, clamped at 100 for the
/// (real) case of available exceeding total. Pure, so the clamp is testable.
pub fn usedPct(total: u64, avail: u64) ?u8 {
    if (total == 0) return null;
    const used = total -| avail;
    return @intCast(@min((used * 100) / total, 100));
}

/// Used memory %, or null when meminfo is unreadable or -- because the read is
/// truncation-aware -- too large to trust whole. A meminfo past the buffer
/// used to look exactly like one with no `MemAvailable`, i.e. "no RAM" instead
/// of the I/O problem it is.
var g_num: [16]u8 = undefined;

fn read() ?systatus.Sample {
    var buf: [4096]u8 = undefined;
    const r = systatus.readFileChecked("/proc/meminfo", &buf) orelse return null;
    if (r.truncated) return null;
    const total = parseRamField(r.bytes, "MemTotal:") orelse return null;
    const avail = parseRamField(r.bytes, "MemAvailable:") orelse return null;
    const pct = usedPct(total, avail) orelse return null;
    return systatus.percentSample(&g_num, pct);
}

/// This readout's binding to the systatus surface (`systatus.Sub`).
pub const sub: systatus.Sub = .{
    .name = "ram",
    .label = "RAM",
    .read = read,
};
