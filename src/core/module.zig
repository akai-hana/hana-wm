//! Generic module state manager.
//! Eliminates boilerplate singleton pattern in tiling, workspaces, and input modules.

const std = @import("std");

/// Generic module state manager with consistent error handling.
///
/// If `StateType` declares a `deinit` method, it must be parameterless
/// (i.e. `fn deinit(self: *StateType) void`). Allocator-taking deinit
/// methods are not supported — the module owns the allocation and destroys
/// it itself after calling `deinit`.
pub fn module(comptime StateType: type) type {
    // Enforce the deinit contract at comptime so violations are caught at the
    // call site rather than producing a cryptic error deep in the generic code.
    comptime if (@hasDecl(StateType, "deinit")) {
        const params = @typeInfo(@TypeOf(StateType.deinit)).@"fn".params;
        if (params.len != 1)
            @compileError(@typeName(StateType) ++ ".deinit must take no arguments other than the receiver");
    };

    return struct {
        var state: ?*StateType = null;

        /// Initialize module state. Returns error if already initialized.
        pub fn init(allocator: std.mem.Allocator, initial_value: StateType) !void {
            if (state != null) return error.AlreadyInitialized;
            const s = try allocator.create(StateType);
            s.* = initial_value;
            state = s;
        }

        /// Deinitialize module state.
        pub fn deinit(allocator: std.mem.Allocator) void {
            const s = state orelse return;
            if (@hasDecl(StateType, "deinit")) s.deinit();
            allocator.destroy(s);
            state = null;
        }

        /// Returns the state pointer, or null if not initialized.
        pub inline fn get() ?*StateType {
            return state;
        }

        /// Returns the state pointer, or error.StateNotInitialized.
        pub inline fn require() !*StateType {
            return state orelse error.StateNotInitialized;
        }
    };
}
