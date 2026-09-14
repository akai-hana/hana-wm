//! Scratch-file helpers for the config/persist test suites.
//!
//! Every test process lazily creates its own uniquely-named directory under
//! the system temp area (never a fixed, shared path like /tmp/opencode, which
//! collides across concurrent agents/CI jobs), writes its files there, and
//! best-effort removes each file (and the dir once empty) on cleanup.

const std = @import("std");

const io = std.Options.debug_io;

var scratch_dir: ?[]const u8 = null;

fn ensureScratchDir() ![]const u8 {
    if (scratch_dir) |dir| return dir;
    // std.crypto.random was dropped in Zig 0.16; seed a local PRNG from the
    // realtime clock plus pid so concurrent test processes still diverge, and
    // use one 64-bit draw as the directory tag.
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts);
    var prng = std.Random.DefaultPrng.init(
        @as(u64, @bitCast(ts.sec)) *% std.time.ns_per_s ^
            @as(u64, @bitCast(ts.nsec)) ^
            @as(u64, @intCast(std.os.linux.getpid())),
    );
    const tag = prng.random().int(u64);
    const dir = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/.hana-test-{x}", .{ "/tmp", tag });
    try std.Io.Dir.createDirAbsolute(io, dir, .default_dir);
    scratch_dir = dir;
    return dir;
}

pub fn scratchPath(alloc: std.mem.Allocator, prefix: []const u8, name: []const u8) ![]u8 {
    const dir = try ensureScratchDir();
    return std.fmt.allocPrint(alloc, "{s}/{s}{s}", .{ dir, prefix, name });
}

pub fn writeScratchFile(abs_path: []const u8, bytes: []const u8) !void {
    _ = try ensureScratchDir();
    const f = try std.Io.Dir.createFileAbsolute(io, abs_path, .{});
    defer f.close(io);
    try f.writePositionalAll(io, bytes, 0);
}

pub fn cleanupScratch(abs_path: []const u8) void {
    std.Io.Dir.deleteFileAbsolute(io, abs_path) catch {};
    if (scratch_dir) |dir| {
        // Best-effort removal of the (now empty, after its last file) dir so
        // runs don't litter /tmp; the next scratchPath re-creates one if a
        // later test still needs it.
        std.Io.Dir.deleteDirAbsolute(io, dir) catch {};
        scratch_dir = null;
    }
}
