//! Build configuration for Hana window manager
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Set the optimization mode (Debug, ReleaseFast, ReleaseSafe, ReleaseSmall)") orelse .ReleaseFast;

    // Create build options for debug logging — one module object, reused everywhere.
    // Previously createModule() was called twice (once here, once inside connectAllModules),
    // producing two separate but identical module objects.
    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_debug_logging", optimize == .Debug);

    // Create the root module
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/core/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Release optimizations
    if (optimize != .Debug) {
        root_module.single_threaded = true;
        root_module.strip = true;
    }

    // Create the executable
    const exe = b.addExecutable(.{
        .name = "hana",
        .root_module = root_module,
    });

    // Set up build-time allocator
    var arena = std.heap.ArenaAllocator.init(b.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Initialize module registry
    var all_modules = std.StringHashMap(*std.Build.Module).init(allocator);

    // Auto-discover modules
    discoverModules(b, "src", target, optimize, allocator, &all_modules) catch |err| {
        std.debug.print("Fatal: Failed to discover modules: {}\n", .{err});
        std.process.exit(1);
    };

    const build_options_module = build_options.createModule();

    // Generate layout_flags.zig as a plain Zig source file reflecting which
    // layout files were found on disk.  Using addWriteFiles rather than
    // addOptions avoids any options-module caching ambiguity — the file's
    // content hash changes exactly when the set of present layouts changes,
    // and it is imported by tiling.zig as a normal @import("layout_flags").
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
    const layout_flags_file   = b.addWriteFiles().add("layout_flags.zig", layout_flags_src);
    const layout_flags_module = b.createModule(.{
        .root_source_file = layout_flags_file,
        .target           = target,
        .optimize         = optimize,
    });

    // Wire up every discovered module:
    //   - give it access to build_options
    //   - give it access to layout_flags (has_master/monocle/grid/fibonacci)
    //   - give it access to every sibling module by name
    //   - register it on root so root can @import("name")
    //
    // Note: we do NOT add root back into each discovered module as "main".
    // Doing so created a full cycle (root → all → root) that forced the Zig
    // frontend and LLVM to treat the entire program as one interconnected unit,
    // defeating per-module incremental analysis and bloating LTO work.
    // If a module genuinely needs to reach into main, it should depend on a
    // shared types/defs module instead.
    root_module.addImport("build_options", build_options_module);
    root_module.addImport("layout_flags",  layout_flags_module);
    connectAllModules(root_module, &all_modules, build_options_module, layout_flags_module, optimize);

    // Link system libraries to root (discovered modules inherit via root)
    linkSystemLibraries(root_module);

    // Install artifact
    b.installArtifact(exe);

    // Create run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run hana");
    run_step.dependOn(&run_cmd.step);
}

fn connectAllModules(
    root: *std.Build.Module,
    modules: *std.StringHashMap(*std.Build.Module),
    build_options_module: *std.Build.Module,
    layout_flags_module: *std.Build.Module,
    optimize: std.builtin.OptimizeMode,
) void {
    var iter = modules.iterator();
    while (iter.next()) |entry| {
        const mod = entry.value_ptr.*;

        // Mirror the same release flags onto every discovered module.
        // Previously these were only set on root_module, so discovered modules
        // were compiled without strip/single_threaded even in ReleaseFast.
        if (optimize != .Debug) {
            mod.single_threaded = true;
            mod.strip = true;
        }

        // Give every module access to build_options (single shared instance).
        mod.addImport("build_options", build_options_module);

        // Give every module access to layout_flags so tiling.zig (and any
        // future module) can query which layout files are present.
        mod.addImport("layout_flags", layout_flags_module);

        // Give every module access to every sibling module by name.
        // addImport only makes the module *available* — Zig compiles lazily,
        // so a module that never calls @import("sibling") pays no compile cost.
        var sibling_iter = modules.iterator();
        while (sibling_iter.next()) |sibling| {
            if (!std.mem.eql(u8, entry.key_ptr.*, sibling.key_ptr.*)) {
                mod.addImport(sibling.key_ptr.*, sibling.value_ptr.*);
            }
        }

        // Register on root so root can @import("name")
        root.addImport(entry.key_ptr.*, mod);
    }
}

fn linkSystemLibraries(root: *std.Build.Module) void {
    root.linkSystemLibrary("xcb", .{});
    root.linkSystemLibrary("xkbcommon", .{});
    root.linkSystemLibrary("xkbcommon-x11", .{});
    root.linkSystemLibrary("X11", .{});
    root.linkSystemLibrary("cairo", .{});
    root.linkSystemLibrary("pangocairo-1.0", .{});
    root.linkSystemLibrary("pango-1.0", .{});
    root.linkSystemLibrary("glib-2.0", .{});
    root.linkSystemLibrary("gobject-2.0", .{});
    root.linkSystemLibrary("xcb-cursor", .{});
    // Include paths are not needed: manual extern declarations are used
    // throughout, so the linker resolves symbols directly from linked libs.
}

fn discoverModules(
    b: *std.Build,
    dir_path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    allocator: std.mem.Allocator,
    all_modules: *std.StringHashMap(*std.Build.Module),
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
        const path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });

        if (all_modules.contains(name)) {
            std.debug.print("Error: Module name collision: '{s}' already exists (found at {s})\n", .{ name, path });
            return error.ModuleNameCollision;
        }

        const module = b.addModule(name, .{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        try all_modules.put(try allocator.dupe(u8, name), module);
    }
}
