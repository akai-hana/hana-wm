/// Error context system for improved debugging
/// Provides structured error logging with contextual information

const std = @import("std");

pub const ErrorContext = struct {
    operation: []const u8,
    window: ?u32 = null,
    workspace: ?usize = null,
    extra: ?[]const u8 = null,
    
    /// Log error with full context
    pub fn log(self: ErrorContext, err: anyerror) void {
        if (self.window) |win| {
            if (self.workspace) |ws| {
                std.log.err("[{s}] Failed: {} (window: 0x{x}, workspace: {})", 
                    .{ self.operation, err, win, ws });
            } else {
                std.log.err("[{s}] Failed: {} (window: 0x{x})", 
                    .{ self.operation, err, win });
            }
        } else if (self.workspace) |ws| {
            std.log.err("[{s}] Failed: {} (workspace: {})", 
                .{ self.operation, err, ws });
        } else {
            std.log.err("[{s}] Failed: {}", .{ self.operation, err });
        }
        
        if (self.extra) |extra| {
            std.log.err("  Additional info: {s}", .{extra});
        }
    }
};

/// Helper function for simpler error logging
pub inline fn logError(
    operation: []const u8,
    err: anyerror,
    window: ?u32,
) void {
    const ctx = ErrorContext{
        .operation = operation,
        .window = window,
    };
    ctx.log(err);
}

/// Helper function with workspace context
pub inline fn logErrorWithWorkspace(
    operation: []const u8,
    err: anyerror,
    window: ?u32,
    workspace: ?usize,
) void {
    const ctx = ErrorContext{
        .operation = operation,
        .window = window,
        .workspace = workspace,
    };
    ctx.log(err);
}
