//! Systatus memory readout.
//! Computes used memory % from MemTotal vs MemAvailable in /proc/meminfo.
//! Null when meminfo is unreadable; the segment then simply skips this item.

const std = @import("std");
const systatus = @import("systatus");

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
fn read() ?u8 {
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

/// This readout's binding to the systatus surface (`systatus.Sub`).
pub const sub: systatus.Sub = .{
    .name = "mem",
    .label = "Mem",
    .read = read,
};

const testing = std.testing;

test "parseMemField extracts the value" {
    const s = "MemTotal:       16299896 kB\nMemAvailable:    12345678 kB\nMemFree:          111 kB\n";
    try testing.expectEqual(@as(?u64, 16299896), parseMemField(s, "MemTotal:"));
    try testing.expectEqual(@as(?u64, 12345678), parseMemField(s, "MemAvailable:"));
    try testing.expectEqual(@as(?u64, null), parseMemField(s, "SwapTotal:"));
}
