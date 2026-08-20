//! Plugin registry.
//! Comptime-built list of optional subsystem plugins gated by build_options.

const build_options = @import("build_options");
const hooks = @import("hooks");

const max_plugins = 8;

pub const list: [max_plugins]hooks.Plugin = blk: {
    var result: [max_plugins]hooks.Plugin = .{hooks.Plugin{}} ** max_plugins;
    var n: usize = 0;

    if (build_options.has_bar) {
        result[n] = @import("bar").plugin;
        n += 1;
    }
    if (build_options.has_floating) {
        result[n] = @import("floating").plugin;
        n += 1;
    }

    break :blk result;
};

pub const count: usize = count: {
    var n: usize = 0;
    for (list) |p| {
        if (p.init != null) n += 1;
    }
    break :count n;
};

pub fn initAll() void {
    inline for (list[0..count]) |p| {
        // Swallow init errors so one failing plugin does not prevent others
        // from starting. A failed subsystem will simply be absent at runtime.
        if (p.init) |f| f() catch {};
    }
}

pub fn deinitAll() void {
    var i = count;
    while (i > 0) {
        i -= 1;
        if (list[i].deinit) |f| f();
    }
}

pub fn fanOut(comptime field: []const u8, args: anytype) void {
    // Dispatches to every plugin that exposes the given optional callback.
    // The inline loop is unrolled at comptime so the branch is resolved per
    // plugin, not at runtime.
    inline for (list[0..count]) |p| {
        if (@field(p, field)) |f| {
            @call(.auto, f, args);
        }
    }
}
