/// Generic module state manager
/// Eliminates boilerplate singleton pattern in tiling, workspaces, and input modules

const std = @import("std");

/// Generic module state manager with consistent error handling
pub fn ModuleState(comptime StateType: type) type {
    return struct {
        const Self = @This();
        
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
            if (state) |s| {
                allocator.destroy(s);
                state = null;
            }
        }
        
        /// Get state reference (optional)
        /// Pass `true` for mutable, `false` for const
        pub inline fn get(comptime mutable: bool) if (mutable) ?*StateType else ?*const StateType {
            return state;
        }
        
        /// Get state reference (required - returns error if not initialized)
        /// Pass `true` for mutable, `false` for const
        pub fn require(comptime mutable: bool) !if (mutable) *StateType else *const StateType {
            return state orelse error.StateNotInitialized;
        }
        
        /// Check if state is initialized
        pub inline fn isInitialized() bool {
            return state != null;
        }
    };
}
