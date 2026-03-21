//! Generic module state manager.
//! Eliminates boilerplate singleton pattern in tiling, workspaces, and input modules.

/// Generic module state manager with consistent error handling.
///
/// If `StateType` declares a `deinit` method, it must be parameterless
/// (i.e. `fn deinit(self: *StateType) void`). Allocator-taking deinit
/// methods are not supported — state is stored inline in static storage
/// and no heap allocation is performed.
pub fn module(comptime StateType: type) type {
    // Enforce the deinit contract at comptime so violations are caught at the
    // call site rather than producing a cryptic error deep in the generic code.
    comptime if (@hasDecl(StateType, "deinit")) {
        const params = @typeInfo(@TypeOf(StateType.deinit)).@"fn".params;
        if (params.len != 1)
            @compileError(@typeName(StateType) ++ ".deinit must take no arguments other than the receiver");
    };

    return struct {
        var state: ?StateType = null;

        /// Initialize module state. Returns error if already initialized.
        pub fn init(initial_value: StateType) !void {
            if (state != null) return error.AlreadyInitialized;
            state = initial_value;
        }

        /// Deinitialize module state.
        pub fn deinit() void {
            if (@hasDecl(StateType, "deinit")) {
                if (state) |*s| s.deinit();
            }
            state = null;
        }

        /// Returns the state pointer, or null if not initialized.
        pub inline fn get() ?*StateType {
            return if (state) |*s| s else null;
        }

        /// Returns the state pointer, or error.StateNotInitialized.
        pub inline fn require() !*StateType {
            return if (state) |*s| s else error.StateNotInitialized;
        }
    };
}
