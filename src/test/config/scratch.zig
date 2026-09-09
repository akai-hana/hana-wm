const std = @import("std");

const io = std.Options.debug_io;
const scratch_dir = "/tmp/opencode";

pub fn scratchPath(alloc: std.mem.Allocator, prefix: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}{s}", .{ scratch_dir, prefix, name });
}

pub fn writeScratchFile(abs_path: []const u8, bytes: []const u8) !void {
    const f = try std.Io.Dir.createFileAbsolute(io, abs_path, .{});
    defer f.close(io);
    try f.writePositionalAll(io, bytes, 0);
}

pub fn cleanupScratch(abs_path: []const u8) void {
    std.Io.Dir.deleteFileAbsolute(io, abs_path) catch {};
}
