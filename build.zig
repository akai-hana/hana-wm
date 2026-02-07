//! Build configuration for Hana window manager
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Set the optimization mode (Debug, ReleaseFast, ReleaseSafe, ReleaseSmall)") orelse .ReleaseFast;

    // Create build options for debug logging
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

    // Add build_options to root module
    root_module.addImport("build_options", build_options.createModule());

    // Connect modules and add build_options to all
    connectAllModules(root_module, &all_modules, build_options);

    // Link system libraries and add include paths to ALL modules
    linkSystemLibrariesAndIncludes(b, root_module, &all_modules);

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

fn connectAllModules(root: *std.Build.Module, modules: *std.StringHashMap(*std.Build.Module), build_options: *std.Build.Step.Options) void {
    const build_options_module = build_options.createModule();
    
    var iter = modules.iterator();
    while (iter.next()) |entry| {
        // Add build_options to this module
        entry.value_ptr.*.addImport("build_options", build_options_module);
        
        var import_iter = modules.iterator();
        while (import_iter.next()) |import| {
            if (!std.mem.eql(u8, entry.key_ptr.*, import.key_ptr.*)) {
                entry.value_ptr.*.addImport(import.key_ptr.*, import.value_ptr.*);
            }
        }
        root.addImport(entry.key_ptr.*, entry.value_ptr.*);
    }
}

fn linkSystemLibrariesAndIncludes(b: *std.Build, root: *std.Build.Module, modules: *std.StringHashMap(*std.Build.Module)) void {
    // Link system libraries to root
    root.linkSystemLibrary("xcb", .{});
    root.linkSystemLibrary("xkbcommon", .{});
    root.linkSystemLibrary("xkbcommon-x11", .{});
    root.linkSystemLibrary("X11", .{});
    root.linkSystemLibrary("Xft", .{});
    root.linkSystemLibrary("Xrender", .{});
    root.linkSystemLibrary("fontconfig", .{});
    
    // Add FreeType include path to root
    addFreetypeIncludes(b, root);
    
    // Add FreeType include path to all discovered modules
    // This is critical because @cImport in any module needs the include paths
    var iter = modules.iterator();
    while (iter.next()) |entry| {
        addFreetypeIncludes(b, entry.value_ptr.*);
    }
}

fn discoverModules(
    b: *std.Build,
    dir_path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    allocator: std.mem.Allocator,
    all_modules: *std.StringHashMap(*std.Build.Module),
) !void {
    // Open directory
    var dir = try b.build_root.handle.openDir(b.graph.io, dir_path, .{ .iterate = true });
    defer dir.close(b.graph.io);

    var iter = dir.iterate();
    while (try iter.next(b.graph.io)) |entry| {
        // Recurse into subdirectories
        if (entry.kind == .directory) {
            const subdir = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            try discoverModules(b, subdir, target, optimize, allocator, all_modules);
            continue;
        }

        // Only process .zig files
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) {
            continue;
        }

        // Extract module name and build path
        const name = std.fs.path.stem(entry.name);
        const path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });

        // Check for name collisions
        if (all_modules.contains(name)) {
            std.debug.print("Error: Module name collision: '{s}' already exists (found at {s})\n", .{ name, path });
            return error.ModuleNameCollision;
        }

        // Create and register module WITH target and optimize mode
        const module = b.addModule(name, .{ 
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        try all_modules.put(try allocator.dupe(u8, name), module);
    }
}

/// Add FreeType include paths (required by Xft.h)
fn addFreetypeIncludes(b: *std.Build, module: *std.Build.Module) void {
    _ = b; // Build context not needed for fallback
    
    // Use standard path - override with CFLAGS if your system differs
    addFreetypeFallback(module);
}

/// Fallback to common FreeType include locations
fn addFreetypeFallback(module: *std.Build.Module) void {
    // Just use the most common path - users can override if needed
    module.addIncludePath(.{ .cwd_relative = "/usr/include/freetype2" });
}
