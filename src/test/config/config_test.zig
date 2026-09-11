//! Config reader tests: readFileAlloc round-trip exactness across size
//! boundaries, the cap enforcement, and the stat-less growth path. The
//! growth path is exercised via /proc (stat.size == 0 but non-empty
//! content) - linux-only by nature, like the WM itself.
//!
//! Scratch files live under /tmp/opencode (pre-approved temp area); each
//! test uses a unique name and cleans up after itself.

const std = @import("std");
const testing = std.testing;

const config = @import("config");
const scratch = @import("scratch");

fn writeAndRead(alloc: std.mem.Allocator, name: []const u8, bytes: []const u8) ![]u8 {
    const path = try scratch.scratchPath(alloc, "hana-cfgtest-", name);
    defer alloc.free(path);
    try scratch.writeScratchFile(path, bytes);
    defer scratch.cleanupScratch(path);
    return config.readFileAlloc(alloc, path);
}

test "readFileAlloc round-trips a >64KiB file exactly" {
    const alloc = testing.allocator;

    // Patterned so any truncation/reorder breaks equality (not just length).
    const big = try alloc.alloc(u8, 70_000);
    defer alloc.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i * 7 + (i % 251));

    const got = try writeAndRead(alloc, "big", big);
    defer alloc.free(got);
    try testing.expectEqualSlices(u8, big, got);
}

test "readFileAlloc accepts exactly max_file_bytes" {
    const alloc = testing.allocator;

    const exact = try alloc.alloc(u8, config.max_file_bytes);
    defer alloc.free(exact);
    @memset(exact, 'x');

    const got = try writeAndRead(alloc, "exact", exact);
    defer alloc.free(got);
    try testing.expectEqual(exact.len, got.len);
}

test "readFileAlloc rejects max_file_bytes + 1" {
    const alloc = testing.allocator;

    const over = try alloc.alloc(u8, config.max_file_bytes + 1);
    defer alloc.free(over);
    @memset(over, 'y');

    try testing.expectError(error.FileTooLarge, writeAndRead(alloc, "over", over));
}

test "readFileAlloc returns empty slice for empty file" {
    const alloc = testing.allocator;

    const got = try writeAndRead(alloc, "empty", "");
    defer alloc.free(got);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "readFileAlloc growth path handles stat-less files (/proc)" {
    const alloc = testing.allocator;
    // /proc/self/status reports stat.size == 0 with real content: forces the
    // fallback read-with-growth loop.
    const got = try config.readFileAlloc(alloc, "/proc/self/status");
    defer alloc.free(got);
    try testing.expect(got.len > 0);
    try testing.expect(std.mem.startsWith(u8, got, "Name:"));
}
