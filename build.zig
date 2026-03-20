//! Build configuration for Hana window manager

const std     = @import("std");
const builtin = @import("builtin");

// Musl compat: weak getauxval fallback for old musl (< 1.1) that lacks it.
//
// The Zig stdlib branches on `link_libc` to decide who owns getauxval:
//
//   link_libc = false  ->  stdlib weakly exports its own getauxvalImpl.
//                          Adding a second export here would trigger Zig's
//                          compile-time "exported symbol collision" error.
//
//   link_libc = true   ->  stdlib assumes libc supplies getauxval and emits
//                          *no* export of its own.  Old musl doesn't have it,
//                          so we must provide a weak fallback ourselves.
//
// Weak linkage means a strong getauxval in libc (musl >= 1.1, glibc) wins at
// link time; the stub is only used when libc has no definition.  Returning 0
// safely disables the VDSO fast-path — syscalls fall back to the normal kernel
// entry point, which is correct and only marginally slower.
comptime {
    if (builtin.os.tag == .linux and builtin.link_libc) {
        const S = struct {
            fn getauxvalFallback(_: usize) callconv(.c) usize { return 0; }
        };
        @export(&S.getauxvalFallback, .{ .name = "getauxval", .linkage = .weak });
    }
}

/// Root source directory. Change this one constant to relocate the entire source tree.
const ROOT_DIR = "src/";

// Optional subsystems
// To make any module or directory optional, add one entry here and guard its
// usage in source with a comptime conditional import:
//
//   const has_foo = @import("build_options").has_foo;
//   const foo = if (has_foo) @import("foo") else struct {
//       // only the symbols THIS file actually calls
//   };
//
//   name         – the @import("name") used throughout the source tree
//   entry_point  – path (relative to build root) to the real entry-point file;
//                  absence of this file sets has_<n> = false in build_options
//   gate_dir     – bare directory name to skip in discoverModules when the
//                  entry point is absent; null for single-file optionals
const OptionalSubsystem = struct {
    name:        []const u8,
    entry_point: []const u8,
    gate_dir:    ?[]const u8 = null,
};

// Add new optional subsystems here
const optional_subsystems = [_]OptionalSubsystem{
    .{
        .name        = "bar",
        .entry_point = ROOT_DIR ++ "bar/bar.zig",
        .gate_dir    = "bar",
    },
    .{
        .name        = "input",
        .entry_point = ROOT_DIR ++ "input/input.zig",
        .gate_dir    = "input",
    },
    .{
        .name        = "dpi",
        .entry_point = ROOT_DIR ++ "core/dpi.zig",
    },
    .{
        .name        = "tiling",
        .entry_point = ROOT_DIR ++ "window/management/tiling/tiling.zig",
        .gate_dir    = "tiling",
    },
    .{
        .name        = "layouts",
        .entry_point = ROOT_DIR ++ "window/management/tiling/layouts.zig",
    },
};
// ▲ Add new optional subsystems here ▲

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize",
        "Set the optimization mode (Debug, ReleaseFast, ReleaseSafe, ReleaseSmall)")
        orelse .ReleaseFast;

    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_debug_logging", optimize == .Debug);

    const fallback_toml = b.build_root.handle.readFileAlloc(
        b.graph.io, "config/fallback.toml", b.allocator, .limited(1024 * 1024),
    ) catch null;
    build_options.addOption(bool,       "has_fallback_toml", fallback_toml != null);
    build_options.addOption([]const u8, "fallback_toml",     fallback_toml orelse "");

    // Emit has_<n> = true/false for every optional subsystem.
    for (optional_subsystems) |sys| {
        build_options.addOption(bool,
            b.fmt("has_{s}", .{sys.name}),
            fileExists(b, sys.entry_point),
        );
    }

    const root_module = b.createModule(.{
        .root_source_file = b.path(ROOT_DIR ++ "core/main.zig"),
        .target    = target,
        .optimize  = optimize,
        .link_libc = true,
    });

    if (optimize == .ReleaseFast or optimize == .ReleaseSmall) root_module.strip = true;

    const exe = b.addExecutable(.{ .name = "hana", .root_module = root_module });

    var all_modules = std.StringHashMap(ModuleEntry).init(b.allocator);

    discoverModules(b, ROOT_DIR, target, optimize, b.allocator, &all_modules) catch |err| {
        std.debug.print("Fatal: failed to discover modules: {}\n", .{err});
        std.process.exit(1);
    };

    // Layout flags: moved into build_options so they are accessible project-wide
    // (e.g. input.zig can gate master-specific actions) rather than being confined
    // to the tiling subsystem via the old layout_flags module.
    build_options.addOption(bool, "has_master",    all_modules.contains("master"));
    build_options.addOption(bool, "has_monocle",   all_modules.contains("monocle"));
    build_options.addOption(bool, "has_grid",      all_modules.contains("grid"));
    build_options.addOption(bool, "has_fibonacci", all_modules.contains("fibonacci"));

    const build_options_module = build_options.createModule();

    const has_any_segment = all_modules.contains("tags")       or
                            all_modules.contains("layout")     or
                            all_modules.contains("variations") or
                            all_modules.contains("title")      or
                            all_modules.contains("clock")      or
                            all_modules.contains("status");

    const bar_flags_src = std.fmt.allocPrint(b.allocator,
        \\pub const has_tags        = {};
        \\pub const has_layout      = {};
        \\pub const has_variations  = {};
        \\pub const has_title       = {};
        \\pub const has_clock       = {};
        \\pub const has_status      = {};
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
    root_module.addImport("bar_flags",     bar_flags_module);

    wireModules(b, root_module, &all_modules,
        build_options_module, bar_flags_module,
        optimize, b.allocator);

    if (all_modules.get("defs")) |defs_entry| {
        var it = all_modules.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.module.addImport("defs", defs_entry.module);
        }
    }

    linkSystemLibraries(root_module, has_any_segment);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run hana").dependOn(&run_cmd.step);
}

const ModuleEntry = struct {
    module:      *std.Build.Module,
    source_path: []const u8,
};

fn wireModules(
    b:                    *std.Build,
    root:                 *std.Build.Module,
    all_modules:          *std.StringHashMap(ModuleEntry),
    build_options_module: *std.Build.Module,
    bar_flags_module:     *std.Build.Module,
    optimize:             std.builtin.OptimizeMode,
    allocator:            std.mem.Allocator,
) void {
    var iter = all_modules.iterator();
    while (iter.next()) |entry| {
        const mod = entry.value_ptr.module;
        if (optimize == .ReleaseFast or optimize == .ReleaseSmall) mod.strip = true;

        mod.addImport("build_options", build_options_module);
        mod.addImport("bar_flags",     bar_flags_module);

        const imports = findModuleImports(b, allocator, entry.value_ptr.source_path, all_modules);
        for (imports) |name| {
            const dep = all_modules.get(name) orelse continue;
            mod.addImport(name, dep.module);
        }

        root.addImport(entry.key_ptr.*, mod);
    }
}

fn findModuleImports(
    b:           *std.Build,
    allocator:   std.mem.Allocator,
    source_path: []const u8,
    all_modules: *std.StringHashMap(ModuleEntry),
) []const []const u8 {
    const source = b.build_root.handle.readFileAlloc(
        b.graph.io, source_path, allocator, .limited(1024 * 1024),
    ) catch return &.{};

    var results: std.ArrayListUnmanaged([]const u8) = .empty;
    const needle = "@import(\"";
    var pos: usize = 0;
    while (std.mem.indexOf(u8, source[pos..], needle)) |rel| {
        const abs = pos + rel;

        // Skip if this @import is on a comment line.
        const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..abs], '\n')) |n| n + 1 else 0;
        const line_prefix = std.mem.trimStart(u8, source[line_start..abs], " \t");
        if (std.mem.startsWith(u8, line_prefix, "//")) {
            pos = abs + needle.len;
            continue;
        }

        pos = abs + needle.len;
        const end = std.mem.indexOfScalar(u8, source[pos..], '"') orelse continue;
        const name = source[pos .. pos + end];
        pos += end + 1;
        if (all_modules.contains(name))
            results.append(allocator, name) catch continue;
    }
    return results.toOwnedSlice(allocator) catch &.{};
}

fn linkSystemLibraries(root: *std.Build.Module, has_bar: bool) void {
    root.linkSystemLibrary("X11", .{});
    root.linkSystemLibrary("xcb", .{});
    root.linkSystemLibrary("xcb-cursor", .{});
    root.linkSystemLibrary("xcb-keysyms", .{});
    root.linkSystemLibrary("xkbcommon", .{});
    root.linkSystemLibrary("xkbcommon-x11", .{});

    if (has_bar) {
        root.linkSystemLibrary("cairo", .{});
        root.linkSystemLibrary("pangocairo-1.0", .{});
        root.linkSystemLibrary("pango-1.0", .{});
        root.linkSystemLibrary("glib-2.0", .{});
        root.linkSystemLibrary("gobject-2.0", .{});
    }
}

fn fileExists(b: *std.Build, path: []const u8) bool {
    _ = b.build_root.handle.statFile(b.graph.io, path, .{}) catch return false;
    return true;
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
            if (entry.name[0] == '.') continue;

            // Skip gated directories whose entry-point file is absent.
            const skip = blk: {
                for (optional_subsystems) |sys| {
                    const gd = sys.gate_dir orelse continue;
                    if (std.mem.eql(u8, entry.name, gd))
                        break :blk !fileExists(b, sys.entry_point);
                }
                break :blk false;
            };
            if (skip) continue;

            const subdir = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            try discoverModules(b, subdir, target, optimize, allocator, all_modules);
            continue;
        }

        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        if (std.mem.eql(u8, entry.name, "main.zig")) continue;

        const name     = std.fs.path.stem(entry.name);
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
