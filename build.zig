// Build configuration for Hana window manager
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseFast, // Optimize by default
    });

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

    // Link-Time Optimization is handled automatically by ReleaseFast in newer Zig

    // Set up build-time allocator
    var arena = std.heap.ArenaAllocator.init(b.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Initialize module registry
    var all_modules = std.StringHashMap(*std.Build.Module).init(allocator);

    // Register core modules
    const core_modules = [_]struct { []const u8, []const u8 }{
        .{ "defs", "src/core/defs.zig" },
        .{ "error", "src/core/error.zig" },
        .{ "toml", "src/core/toml.zig" },
        .{ "config", "src/core/config.zig" },
        .{ "xkbcommon", "src/core/xkbcommon.zig" },
    };

    for (core_modules) |mod| {
        const module = b.addModule(mod[0], .{ .root_source_file = b.path(mod[1]) });
        all_modules.put(mod[0], module) catch @panic("Failed to register core module");
    }

    // Auto-discover modules
    discoverModules(b, "src", allocator, &all_modules) catch |err| {
        std.debug.print("Fatal: Failed to discover modules: {}\n", .{err});
        std.process.exit(1);
    };

    // Connect modules
    connectAllModules(root_module, &all_modules);

    // Link system libraries
    root_module.linkSystemLibrary("xcb", .{});
    root_module.linkSystemLibrary("xkbcommon", .{});
    root_module.linkSystemLibrary("xkbcommon-x11", .{});

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

fn connectAllModules(root: *std.Build.Module, modules: *std.StringHashMap(*std.Build.Module)) void {
    var iter = modules.iterator();
    while (iter.next()) |entry| {
        var import_iter = modules.iterator();
        while (import_iter.next()) |import| {
            if (!std.mem.eql(u8, entry.key_ptr.*, import.key_ptr.*)) {
                entry.value_ptr.*.addImport(import.key_ptr.*, import.value_ptr.*);
            }
        }
        root.addImport(entry.key_ptr.*, entry.value_ptr.*);
    }
}

fn discoverModules(
    b: *std.Build,
    dir_path: []const u8,
    allocator: std.mem.Allocator,
    all_modules: *std.StringHashMap(*std.Build.Module),
) !void {
    // Set up I/O for directory operations
    var io_threaded: std.Io.Threaded = .init_single_threaded;
    const io = io_threaded.io();

    // Open directory
    var dir = b.build_root.handle.openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("Cannot open directory '{s}': {}\n", .{ dir_path, err });
        return err;
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        // Skip src/core directory
        if (std.mem.eql(u8, dir_path, "src") and 
            entry.kind == .directory and 
            std.mem.eql(u8, entry.name, "core")) 
        {
            continue;
        }

        // Recurse into subdirectories
        if (entry.kind == .directory) {
            const subdir = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            try discoverModules(b, subdir, allocator, all_modules);
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

        // Create and register module
        const module = b.addModule(name, .{ .root_source_file = b.path(path) });
        try all_modules.put(try allocator.dupe(u8, name), module);
    }
}
