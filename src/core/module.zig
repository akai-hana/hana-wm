/// Generic module state manager
/// Eliminates boilerplate singleton pattern in tiling, workspaces, and input modules

const std = @import("std");

/// Generic module state manager with consistent error handling
pub fn module(comptime StateType: type) type {
    return struct {
        var state: ?*StateType = null;

        /// Initialize module state
        /// Returns error if already initialized
        pub fn init(allocator: std.mem.Allocator, initial_value: StateType) !void {
            if (state != null) return error.AlreadyInitialized;

            const s = try allocator.create(StateType);
            errdefer allocator.destroy(s);
            s.* = initial_value;
            state = s;
        }

        /// Deinitialize module state
        pub fn deinit(allocator: std.mem.Allocator) void {
            const s = state orelse return;
            if (@hasDecl(StateType, "deinit")) s.deinit();
            allocator.destroy(s);
            state = null;
        }

        /// Get state reference (optional)
        pub inline fn get() ?*StateType {
            return state;
        }

        /// Get state reference (required - returns error if not initialized)
        pub inline fn require() !*StateType {
            return state orelse error.StateNotInitialized;
        }

        /// Check if state is initialized
        pub inline fn isInitialized() bool {
            return state != null;
        }
    };
}
