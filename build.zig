// Build config for Zig: compile, link, install, run.

const std = @import("std");

pub fn build(b: *std.Build) void {
    // SELECTIONS
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create root module first
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/core/main.zig"),

        .target = target,
        .optimize = optimize,
        .link_libc = true, //
    });

    // ARTIFACTS
    const exe = b.addExecutable(.{
        .name = "hana",
        .root_module = root_module,
    });

    // Core modules

    // Definitions
    const defs_module = b.addModule("defs", .{
        .root_source_file = b.path("src/core/defs.zig"),
    });
    exe.root_module.addImport("defs", defs_module);

    // Error handling
    const error_module = b.addModule("error", .{
        .root_source_file = b.path("src/core/error.zig"),
    });
    error_module.addImport("defs", defs_module);
    exe.root_module.addImport("error", error_module);

    // Custom TOML parser
    const toml_module = b.addModule("toml", .{
        .root_source_file = b.path("src/core/toml.zig"),
    });
    exe.root_module.addImport("toml", toml_module);

    // Config parser
    const config_module = b.addModule("config", .{
        .root_source_file = b.path("src/core/config.zig"),
    });
    config_module.addImport("error", error_module);
    config_module.addImport("defs", defs_module);
    config_module.addImport("toml", toml_module);
    exe.root_module.addImport("config", config_module);

    // Auto-register all user modules (everything in src/ except src/core/, which must be added manually)
    var arena = std.heap.ArenaAllocator.init(b.allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // 
    autoRegisterModules(b, exe.root_module, defs_module, "src", arena_allocator) catch |err| {
        std.debug.print("Fatal: Failed to auto-register modules: {}\n", .{err});
        std.process.exit(1);
    };

    // LINKING
    exe.root_module.linkSystemLibrary("xcb", .{});

    // INSTALL
    b.installArtifact(exe);

    // RUN
    const run_hana = b.addRunArtifact(exe);
    run_hana.step.dependOn(b.getInstallStep());

    // Forward CLI args (commented for now, may be useful later)
    // if (b.args) |args| {
    //     run_hana.addArgs(args);
    // }

    const run_step = b.step("run", "Run hana");
    run_step.dependOn(&run_hana.step);
}

// Module auto-detection and registration logic
fn autoRegisterModules(
    b: *std.Build,
    root_module: *std.Build.Module,
    defs_module: *std.Build.Module,
    dir_path: []const u8,
    allocator: std.mem.Allocator,
) !void {
    // Track registered module names to detect collisions
    var registered_modules = std.StringHashMap([]const u8).init(allocator);
    defer registered_modules.deinit();

    try autoRegisterModulesRecursive(b, root_module, defs_module, dir_path, allocator, &registered_modules);
}

fn autoRegisterModulesRecursive(
    b: *std.Build,
    root_module: *std.Build.Module,
    defs_module: *std.Build.Module,
    dir_path: []const u8,
    allocator: std.mem.Allocator,
    registered_modules: *std.StringHashMap([]const u8),
) !void {
    // Create Io instance for filesystem operations (single-threaded is fine for build script)
    var io_threaded: std.Io.Threaded = .init_single_threaded;
    const io = io_threaded.io();

    // Critical error: Can't open directory
    var dir = b.build_root.handle.openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("Critical: Cannot open directory '{s}': {}\n", .{ dir_path, err });
        return err;
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        // Skip src/core/ directory entirely (core modules are manually registered)
        const is_src_core = std.mem.eql(u8, dir_path, "src") and
            entry.kind == .directory and
            std.mem.eql(u8, entry.name, "core");
        if (is_src_core) continue;

        // Handle subdirectories recursively
        if (entry.kind == .directory) {
            var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const subdir_path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ dir_path, entry.name });
            try autoRegisterModulesRecursive(b, root_module, defs_module, subdir_path, allocator, registered_modules);
            continue;
        }

        // Only process .zig files
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;

        // Extract module name (filename without .zig extension)
        const module_name = std.fs.path.stem(entry.name);

        // Build full path using stack buffer (memory-efficient)
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ dir_path, entry.name });

        // Check for name collision
        if (registered_modules.get(module_name)) |existing_path| {
            std.debug.print(
                \\
                \\Error: Module name collision detected: '{s}'
                \\  Existing: {s}
                \\  New:      {s}
                \\
                \\Please rename one of these files to avoid conflicts.
                \\
                , .{ module_name, existing_path, full_path });
            return error.ModuleNameCollision;
        }

        // Register module
        const module = b.createModule(.{
            .root_source_file = b.path(full_path),
        });
        module.addImport("defs", defs_module);
        root_module.addImport(module_name, module);

        // Track this module name (store path for collision error messages)
        try registered_modules.put(module_name, try allocator.dupe(u8, full_path));

        std.debug.print("Registered module: {s} ({s})\n", .{ module_name, full_path });
    }
}
