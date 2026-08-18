//! Comptime-generated plugin list for optional subsystems.
//!
//! Conditionally includes each subsystem's plugin based on build_options,
//! and provides list, count, initAll(), deinitAll(), and fanOut().

const build_options = @import("build_options");
const hooks = @import("hooks");

/// Maximum number of simultaneous plugins.
const MAX_PLUGINS = 8;

/// Comptime-built list of registered plugins. Only includes subsystems that exist.
pub const list: [MAX_PLUGINS]hooks.Plugin = blk: {
    var result: [MAX_PLUGINS]hooks.Plugin = .{hooks.Plugin{}} ** MAX_PLUGINS;
    var n: usize = 0;

    if (build_options.has_bar) {
        result[n] = @import("bar").plugin;
        n += 1;
    }
    if (build_options.has_tiling) {
        result[n] = @import("tiling").plugin;
        n += 1;
    }
    if (build_options.has_drag) {
        result[n] = @import("drag").plugin;
        n += 1;
    }
    if (build_options.has_floating) {
        result[n] = @import("floating").plugin;
        n += 1;
    }

    break :blk result;
};

/// Number of active plugins.
pub const count: usize = count: {
    var n: usize = 0;
    if (build_options.has_bar) n += 1;
    if (build_options.has_tiling) n += 1;
    if (build_options.has_drag) n += 1;
    if (build_options.has_floating) n += 1;
    break :count n;
};

/// Initialize all plugins in order. Called from main.zig.
pub fn initAll() void {
    inline for (list[0..count]) |p| {
        if (p.init) |f| f() catch {};
    }
}

/// Deinitialize all plugins in reverse order. Called from main.zig.
pub fn deinitAll() void {
    var i = count;
    while (i > 0) {
        i -= 1;
        if (list[i].deinit) |f| f();
    }
}

/// Fan-out: call a Plugin field on all plugins that have it.
/// Used for events that multiple plugins need to observe.
pub fn fanOut(comptime field: []const u8, args: anytype) void {
    inline for (list[0..count]) |p| {
        if (@field(p, field)) |f| {
            @call(.auto, f, args);
        }
    }
}
