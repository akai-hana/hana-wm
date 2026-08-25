//! Config reader tests: readFileAlloc round-trip exactness across size
//! boundaries, the cap enforcement, and the stat-less growth path. The
//! growth path is exercised via /proc (stat.size == 0 but non-empty
//! content) — linux-only by nature, like the WM itself.
//!
//! Scratch files live under /tmp/opencode (pre-approved temp area); each
//! test uses a unique name and cleans up after itself.

const std = @import("std");
const testing = std.testing;

const config = @import("config");

const io = std.Options.debug_io;
const scratch_dir = "/tmp/opencode";

fn scratchPath(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/hana-cfgtest-{s}", .{ scratch_dir, name });
}

fn writeScratchFile(abs_path: []const u8, bytes: []const u8) !void {
    const f = try std.Io.Dir.createFileAbsolute(io, abs_path, .{});
    defer f.close(io);
    try f.writePositionalAll(io, bytes, 0);
}

fn cleanupScratch(abs_path: []const u8) void {
    std.Io.Dir.deleteFileAbsolute(io, abs_path) catch {};
}

test "C1 readFileAlloc round-trips a >64KiB file exactly" {
    const alloc = testing.allocator;

    // Patterned so any truncation/reorder breaks equality (not just length).
    const big = try alloc.alloc(u8, 70_000);
    defer alloc.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i * 7 + (i % 251));

    const path = try scratchPath(alloc, "big");
    defer alloc.free(path);
    try writeScratchFile(path, big);
    defer cleanupScratch(path);

    const got = try config.readFileAlloc(alloc, path);
    defer alloc.free(got);
    try testing.expectEqualSlices(u8, big, got);
}

test "C2 readFileAlloc accepts exactly max_file_bytes" {
    const alloc = testing.allocator;

    const exact = try alloc.alloc(u8, config.max_file_bytes);
    defer alloc.free(exact);
    @memset(exact, 'x');

    const path = try scratchPath(alloc, "exact");
    defer alloc.free(path);
    try writeScratchFile(path, exact);
    defer cleanupScratch(path);

    const got = try config.readFileAlloc(alloc, path);
    defer alloc.free(got);
    try testing.expectEqual(exact.len, got.len);
}

test "C3 readFileAlloc rejects max_file_bytes + 1" {
    const alloc = testing.allocator;

    const over = try alloc.alloc(u8, config.max_file_bytes + 1);
    defer alloc.free(over);
    @memset(over, 'y');

    const path = try scratchPath(alloc, "over");
    defer alloc.free(path);
    try writeScratchFile(path, over);
    defer cleanupScratch(path);

    const got = config.readFileAlloc(alloc, path);
    try testing.expectError(error.FileTooLarge, got);
}

test "C4 readFileAlloc returns empty slice for empty file" {
    const alloc = testing.allocator;

    const path = try scratchPath(alloc, "empty");
    defer alloc.free(path);
    try writeScratchFile(path, "");
    defer cleanupScratch(path);

    const got = try config.readFileAlloc(alloc, path);
    defer alloc.free(got);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "C5 readFileAlloc growth path handles stat-less files (/proc)" {
    const alloc = testing.allocator;
    // /proc/self/status reports stat.size == 0 with real content: forces the
    // fallback read-with-growth loop.
    const got = try config.readFileAlloc(alloc, "/proc/self/status");
    defer alloc.free(got);
    try testing.expect(got.len > 0);
    try testing.expect(std.mem.startsWith(u8, got, "Name:"));
}
