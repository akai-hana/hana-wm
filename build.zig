//! Build configuration for Hana window manager
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize",
        "Set the optimization mode (Debug, ReleaseFast, ReleaseSafe, ReleaseSmall)")
        orelse .ReleaseFast;

    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_debug_logging", optimize == .Debug);

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/core/main.zig"),
        .target    = target,
        .optimize  = optimize,
        .link_libc = true,
    });

    if (optimize != .Debug) {
        root_module.single_threaded = true;
        root_module.strip = true;
    }

    const exe = b.addExecutable(.{ .name = "hana", .root_module = root_module });

    var arena = std.heap.ArenaAllocator.init(b.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // name -> (module, absolute source path)
    var all_modules = std.StringHashMap(ModuleEntry).init(allocator);

    discoverModules(b, "src", target, optimize, allocator, &all_modules) catch |err| {
        std.debug.print("Fatal: failed to discover modules: {}\n", .{err});
        std.process.exit(1);
    };

    const build_options_module = build_options.createModule();

    const layout_flags_src = std.fmt.allocPrint(allocator,
        \\pub const has_master    = {};
        \\pub const has_monocle   = {};
        \\pub const has_grid      = {};
        \\pub const has_fibonacci = {};
        \\
    , .{
        all_modules.contains("master"),
        all_modules.contains("monocle"),
        all_modules.contains("grid"),
        all_modules.contains("fibonacci"),
    }) catch @panic("OOM");

    const layout_flags_module = b.createModule(.{
        .root_source_file = b.addWriteFiles().add("layout_flags.zig", layout_flags_src),
        .target   = target,
        .optimize = optimize,
    });

    // bar_flags: tells bar.zig which segment module files are present on disk.
    // When has_any_segment is false, BarFull is never analyzed by Zig's lazy
    // evaluator, so drawing.zig is never compiled and cairo/pango are not linked.
    const has_any_segment = all_modules.contains("tags")       or
                            all_modules.contains("layout")     or
                            all_modules.contains("variations") or
                            all_modules.contains("title")      or
                            all_modules.contains("clock")      or
                            all_modules.contains("status");

    const bar_flags_src = std.fmt.allocPrint(allocator,
        \\pub const has_tags       = {};
        \\pub const has_layout     = {};
        \\pub const has_variations = {};
        \\pub const has_title      = {};
        \\pub const has_clock      = {};
        \\pub const has_status     = {};
        \\pub const has_any_segment = {};
        \\
    , .{
        all_modules.contains("tags"),
        all_modules.contains("layout"),
        all_modules.contains("variations"),
        all_modules.contains("title"),
        all_modules.contains("clock"),
        all_modules.contains("status"),
        has_any_segment,
    }) catch @panic("OOM");

    const bar_flags_module = b.createModule(.{
        .root_source_file = b.addWriteFiles().add("bar_flags.zig", bar_flags_src),
        .target   = target,
        .optimize = optimize,
    });

    root_module.addImport("build_options", build_options_module);
    root_module.addImport("layout_flags",  layout_flags_module);
    root_module.addImport("bar_flags",     bar_flags_module);

    // Wire each module based on what it actually @imports.
    wireModules(b, root_module, &all_modules, build_options_module, layout_flags_module, bar_flags_module, optimize, allocator);

    linkSystemLibraries(root_module, has_any_segment);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run hana").dependOn(&run_cmd.step);
}

const ModuleEntry = struct {
    module:      *std.Build.Module,
    source_path: []const u8, // path relative to build root
};

fn wireModules(
    b:                    *std.Build,
    root:                 *std.Build.Module,
    all_modules:          *std.StringHashMap(ModuleEntry),
    build_options_module: *std.Build.Module,
    layout_flags_module:  *std.Build.Module,
    bar_flags_module:     *std.Build.Module,
    optimize:             std.builtin.OptimizeMode,
    allocator:            std.mem.Allocator,
) void {
    var iter = all_modules.iterator();
    while (iter.next()) |entry| {
        const mod = entry.value_ptr.module;

        if (optimize != .Debug) {
            mod.single_threaded = true;
            mod.strip = true;
        }

        mod.addImport("build_options", build_options_module);
        mod.addImport("layout_flags",  layout_flags_module);
        mod.addImport("bar_flags",     bar_flags_module);

        // Read the source file and wire only the @imports that are known modules.
        const imports = findModuleImports(b, allocator, entry.value_ptr.source_path, all_modules);
        for (imports) |name| {
            const dep = all_modules.get(name) orelse continue;
            mod.addImport(name, dep.module);
        }

        // Expose every module on root so main.zig can import it.
        root.addImport(entry.key_ptr.*, mod);
    }
}

/// Reads `source_path` (relative to build root) and returns every @import("name")
/// where `name` is a key in `all_modules`. Slices point into arena-allocated
/// source bytes — safe because the arena outlives the entire build() call.
fn findModuleImports(
    b:           *std.Build,
    allocator:   std.mem.Allocator,
    source_path: []const u8,
    all_modules: *std.StringHashMap(ModuleEntry),
) []const []const u8 {
    const source = std.Io.Dir.readFileAlloc(
        b.build_root.handle, b.graph.io, source_path, allocator, .limited(1024 * 1024),
    ) catch return &.{};
    // Do NOT free source — name slices below point into it.

    var results: std.ArrayList([]const u8) = .empty;
    const needle = "@import(\"";
    var pos: usize = 0;
    while (std.mem.indexOf(u8, source[pos..], needle)) |rel| {
        pos += rel + needle.len;
        const end = std.mem.indexOfScalar(u8, source[pos..], '"') orelse continue;
        const name = source[pos .. pos + end];
        pos += end + 1;
        if (all_modules.contains(name))
            results.append(allocator, name) catch continue;
    }
    return results.toOwnedSlice(allocator) catch &.{};
}

fn linkSystemLibraries(root: *std.Build.Module, has_bar: bool) void {
    root.linkSystemLibrary("xcb", .{});
    root.linkSystemLibrary("xkbcommon", .{});
    root.linkSystemLibrary("xkbcommon-x11", .{});
    root.linkSystemLibrary("X11", .{});
    root.linkSystemLibrary("xcb-cursor", .{});

    // Cairo, Pango, GLib, and GObject are only needed when at least one bar
    // segment module is present. With zero segments, BarFull is never analyzed,
    // drawing.zig is never compiled, and these symbols are never referenced.
    if (has_bar) {
        root.linkSystemLibrary("cairo", .{});
        root.linkSystemLibrary("pangocairo-1.0", .{});
        root.linkSystemLibrary("pango-1.0", .{});
        root.linkSystemLibrary("glib-2.0", .{});
        root.linkSystemLibrary("gobject-2.0", .{});
    }
}

fn discoverModules(
    b:           *std.Build,
    dir_path:    []const u8,
    target:      std.Build.ResolvedTarget,
    optimize:    std.builtin.OptimizeMode,
    allocator:   std.mem.Allocator,
    all_modules: *std.StringHashMap(ModuleEntry),
) !void {
    var dir = try b.build_root.handle.openDir(b.graph.io, dir_path, .{ .iterate = true });
    defer dir.close(b.graph.io);

    var iter = dir.iterate();
    while (try iter.next(b.graph.io)) |entry| {
        if (entry.kind == .directory) {
            const subdir = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            try discoverModules(b, subdir, target, optimize, allocator, all_modules);
            continue;
        }

        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        if (std.mem.eql(u8, entry.name, "main.zig")) continue;

        const name = std.fs.path.stem(entry.name);
        const rel_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });

        if (all_modules.contains(name)) {
            std.debug.print("Error: module name collision: '{s}' (at {s})\n", .{ name, rel_path });
            return error.ModuleNameCollision;
        }

        try all_modules.put(try allocator.dupe(u8, name), .{
            .module = b.addModule(name, .{
                .root_source_file = b.path(rel_path),
                .target   = target,
                .optimize = optimize,
            }),
            .source_path = rel_path,
        });
    }
}
