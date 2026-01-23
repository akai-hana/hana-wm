//! Error handling and validation utilities

const std = @import("std");

/// Check XCB request for errors and log them
pub fn xcbCheckError(conn: anytype, cookie: anytype, operation: []const u8) bool {
    const xcb = @import("defs").xcb;
    if (xcb.xcb_request_check(conn, cookie)) |err| {
        std.log.err("[XCB] {s} failed: error_code={}", .{ operation, err.*.error_code });
        std.c.free(err);
        return false;
    }
    return true;
}

/// Assert that a condition is true, with a custom error message
pub inline fn assert(condition: bool, comptime message: []const u8) void {
    if (!condition) {
        std.log.err("[ASSERT FAILED] {s}", .{message});
        @panic(message);
    }
}

/// Check if a pointer is null and log error if so
pub inline fn checkNull(comptime T: type, ptr: ?*T, comptime name: []const u8) ?*T {
    if (ptr == null) {
        std.log.err("[NULL CHECK] {s} is null", .{name});
    }
    return ptr;
}
