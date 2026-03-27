///! Build configuration for Hana window manager

const std     = @import("std");
const builtin = @import("builtin");

const ROOT_DIR = "src/";

// Each subsystem gets a `has_<n>` build option derived from whether its
// file is discovered. Absence of an entry point also gates the whole directory
// when that directory is named after the subsystem and contains a same-named
// .zig file (e.g. bar/bar.zig, tiling/tiling.zig) — see isGatedOut.
// Segment subsystems additionally contribute to `has_any_segment`.
const OptionalSubsystem = struct {
    name:       []const u8,
    is_segment: bool = false,
};

// Append to this list to add new optional subsystems, layouts, or bar segments.
const optional_subsystems = [_]OptionalSubsystem{
    // core/modules/
    .{ .name = "scale" },
    .{ .name = "debug" },

    // window/modules/
    .{ .name = "fullscreen" },
    .{ .name = "minimize"   },
    .{ .name = "workspaces" },

    // tiling/
    .{ .name = "tiling"  },
    .{ .name = "layouts" },

    // tiling/modules/
    .{ .name = "master"    },
    .{ .name = "monocle"   },
    .{ .name = "grid"      },
    .{ .name = "fibonacci" },

    // bar/
    .{ .name = "bar" },

    // bar/modules/
    .{ .name = "prompt" },
    .{ .name = "tags",     .is_segment = true },
    .{ .name = "layout",   .is_segment = true },
    .{ .name = "variants", .is_segment = true },
    .{ .name = "title",    .is_segment = true },
    .{ .name = "carousel", .is_segment = true },
    .{ .name = "clock",    .is_segment = true },
};

pub fn build(b: *std.Build) void {
    if (builtin.zig_version.pre == null) {
        @compileError(
            \\Please compile hana with Zig's master branch.
            \\If your package manager doesn't have it, you can try using ZVM:
            \\$ curl https://raw.githubusercontent.com/tristanisham/zvm/master/install.sh | bash
        );
    }

    const build_options = b.addOptions();

    // Release
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });
    const target   = b.standardTargetOptions(.{});

    // Debug
    build_options.addOption(bool, "enable_debug_logging", optimize == .Debug);

    // b.allocator is a build-lifetime arena; intermediate allocations are not freed individually.
    const fallback_toml = b.build_root.handle.readFileAlloc(
        b.graph.io, "config/fallback.toml", b.allocator, .limited(1024 * 1024),
    ) catch null;
    build_options.addOption(bool, "has_fallback_toml", fallback_toml != null);

    // Write the raw TOML alongside the module so @embedFile can reference it
    const wf = b.addWriteFiles();
    if (fallback_toml) |content| _ = wf.add("fallback.toml", content);
    const fallback_toml_module = b.createModule(.{
        .root_source_file = wf.add("fallback_toml.zig",
            if (fallback_toml != null)
                \\pub const content: []const u8 = @embedFile("fallback.toml");
            else
                \\pub const content: []const u8 = "";
        ),
        .target   = target,
        .optimize = optimize,
    });

    const root_module = b.createModule(.{
        .root_source_file = b.path(ROOT_DIR ++ "core/main.zig"),
        .target    = target,
        .optimize  = optimize,
        .link_libc = true,
    });
    maybeStrip(root_module, optimize);

    const exe = b.addExecutable(.{ .name = "hana", .root_module = root_module });

    var all_modules = std.StringHashMap(ModuleEntry).init(b.allocator);

    discoverModules(b, ROOT_DIR, target, optimize, &all_modules) catch |err| {
        std.debug.print("Fatal: failed to discover modules: {}\n", .{err});
        std.process.exit(1);
    };

    var has_any_segment = false;
    for (optional_subsystems) |sys| {
        const present = all_modules.contains(sys.name);
        build_options.addOption(bool, b.fmt("has_{s}", .{sys.name}), present);
        if (sys.is_segment) has_any_segment = has_any_segment or present;
    }
    build_options.addOption(bool, "has_any_segment", has_any_segment);

    const ctx: BuildCtx = .{
        .build_options = build_options.createModule(),
        .fallback_toml = fallback_toml_module,
        .optimize      = optimize,
    };

    root_module.addImport("build_options", ctx.build_options);
    root_module.addImport("fallback_toml", ctx.fallback_toml);

    wireModules(root_module, &all_modules, ctx);
    linkSystemLibraries(root_module, has_any_segment);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run hana").dependOn(&run_cmd.step);

    const check = b.step("check", "Type-check without installing");
    check.dependOn(&exe.step);

    _ = b.step("test", "Run unit tests");
}

// Types & helpers 

const ModuleEntry = struct {
    module:      *std.Build.Module,
    source_path: []const u8,
};

const BuildCtx = struct {
    build_options: *std.Build.Module,
    fallback_toml: *std.Build.Module,
    optimize:      std.builtin.OptimizeMode,
};

inline fn maybeStrip(mod: *std.Build.Module, optimize: std.builtin.OptimizeMode) void {
    if (optimize == .ReleaseFast or optimize == .ReleaseSmall) mod.strip = true;
}

// A directory is gated out when a subsystem of the same name exists and its
// conventional entry point — <dir_path>/<dir_name>/<dir_name>.zig — is absent.
fn isGatedOut(b: *std.Build, dir_path: []const u8, dir_name: []const u8) bool {
    for (optional_subsystems) |sys| {
        if (!std.mem.eql(u8, sys.name, dir_name)) continue;
        const entry = b.pathJoin(&.{ dir_path, dir_name, b.fmt("{s}.zig", .{dir_name}) });
        return !fileExists(b, entry);
    }
    return false;
}

fn fileExists(b: *std.Build, path: []const u8) bool {
    _ = b.build_root.handle.statFile(b.graph.io, path, .{}) catch return false;
    return true;
}

// Module wiring 

// Wires every discovered module into root, and cross-wires all modules with each
// other. Unused imports cost nothing at compile time, so the explicit per-file
// import scanning that was here previously is not needed.
fn wireModules(
    root:        *std.Build.Module,
    all_modules: *std.StringHashMap(ModuleEntry),
    ctx:         BuildCtx,
) void {
    var iter = all_modules.iterator();
    while (iter.next()) |entry| {
        const mod = entry.value_ptr.module;
        maybeStrip(mod, ctx.optimize);
        mod.addImport("build_options", ctx.build_options);
        mod.addImport("fallback_toml", ctx.fallback_toml);

        var deps = all_modules.iterator();
        while (deps.next()) |dep| {
            if (!std.mem.eql(u8, dep.key_ptr.*, entry.key_ptr.*))
                mod.addImport(dep.key_ptr.*, dep.value_ptr.module);
        }

        root.addImport(entry.key_ptr.*, mod);
    }
}

fn linkSystemLibraries(root: *std.Build.Module, has_any_segment: bool) void {
    root.linkSystemLibrary("X11", .{});
    root.linkSystemLibrary("xcb", .{});
    root.linkSystemLibrary("xcb-cursor", .{});
    root.linkSystemLibrary("xcb-keysyms", .{});
    root.linkSystemLibrary("xkbcommon", .{});
    root.linkSystemLibrary("xkbcommon-x11", .{});

    if (has_any_segment) {
        root.linkSystemLibrary("cairo", .{});
        root.linkSystemLibrary("pangocairo-1.0", .{});
        root.linkSystemLibrary("pango-1.0", .{});
        root.linkSystemLibrary("glib-2.0", .{});
        root.linkSystemLibrary("gobject-2.0", .{});
    }
}

// Module discovery 

fn discoverModules(
    b:           *std.Build,
    dir_path:    []const u8,
    target:      std.Build.ResolvedTarget,
    optimize:    std.builtin.OptimizeMode,
    all_modules: *std.StringHashMap(ModuleEntry),
) !void {
    var dir = try b.build_root.handle.openDir(b.graph.io, dir_path, .{ .iterate = true });
    defer dir.close(b.graph.io);

    var iter = dir.iterate();
    while (try iter.next(b.graph.io)) |entry| {
        if (entry.kind == .directory) {
            if (std.mem.startsWith(u8, entry.name, ".")) continue;
            if (isGatedOut(b, dir_path, entry.name)) continue;

            const subdir = try std.fs.path.join(b.allocator, &.{ dir_path, entry.name });
            try discoverModules(b, subdir, target, optimize, all_modules);
            continue;
        }

        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        if (std.mem.eql(u8, entry.name, "main.zig")) continue;

        const name     = std.fs.path.stem(entry.name);
        const rel_path = try std.fs.path.join(b.allocator, &.{ dir_path, entry.name });

        if (all_modules.contains(name)) {
            std.debug.print("Error: module name collision: '{s}' (at {s})\n", .{ name, rel_path });
            return error.ModuleNameCollision;
        }

        try all_modules.put(try b.allocator.dupe(u8, name), .{
            .module = b.createModule(.{
                .root_source_file = b.path(rel_path),
                .target   = target,
                .optimize = optimize,
            }),
            .source_path = rel_path,
        });
    }
}
