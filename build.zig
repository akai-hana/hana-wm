///! Build configuration for Hana window manager

const std     = @import("std");
const builtin = @import("builtin");

const ROOT_DIR = "src/";

// An optional subsystem is gated on presence of its entry_point file
// Absence sets `has_<thing> = false` in build_options, and gate_dir is skipped by discoverModules.
const OptionalSubsystem = struct {
    name:        []const u8,
    entry_point: []const u8,
    gate_dir:    ?[]const u8 = null, // directory to skip when entry_point is absent
};

const optional_subsystems = [_]OptionalSubsystem{
    .{ .name = "scale",      .entry_point = ROOT_DIR ++ "core/scale.zig"                                             },
    .{ .name = "bar",        .entry_point = ROOT_DIR ++ "bar/bar.zig",                      .gate_dir = "bar"        },
    .{ .name = "tiling",     .entry_point = ROOT_DIR ++ "window/modules/tiling/tiling.zig", .gate_dir = "tiling"     },
    .{ .name = "layouts",    .entry_point = ROOT_DIR ++ "window/modules/tiling/layouts.zig"                          },
    .{ .name = "fullscreen", .entry_point = ROOT_DIR ++ "window/modules/fullscreen.zig",                             },
    .{ .name = "minimize",   .entry_point = ROOT_DIR ++ "window/modules/minimize.zig"                                },
    .{ .name = "workspaces", .entry_point = ROOT_DIR ++ "window/modules/workspaces.zig"                              },
};

// Append to these lists to add new layouts or bar segments.
// has_<n> build_options and has_any_segment are derived automatically.
const layout_modules = [_][]const u8{
    "master", "monocle", "grid", "fibonacci",
};

const segment_modules = [_][]const u8{
    "tags", "layout", "variants", "title", "clock", "status",
};

pub fn build(b: *std.Build) void {
    if (builtin.zig_version.pre == null) {
        @compileError(
            \\Please compile hana with Zig's master branch.
            \\If your package manager doesn't have it, you can try using ZVM:
            \\$ curl https://raw.githubusercontent.com/tristanisham/zvm/master/install.sh | bash
        );
    }

    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_debug_logging", optimize == .Debug);

    // b.allocator is a build-lifetime arena; intermediate allocations are not
    // freed individually.
    const fallback_toml = b.build_root.handle.readFileAlloc(
        b.graph.io, "config/fallback.toml", b.allocator, .limited(1024 * 1024),
    ) catch null;
    build_options.addOption(bool, "has_fallback_toml", fallback_toml != null);

    // Stored in a separate module because build_options can't hold []const u8.
    const fallback_toml_src = std.fmt.allocPrint(b.allocator,
        "pub const content: []const u8 = \"{s}\";",
        .{zigEscape(b.allocator, fallback_toml orelse "")},
    ) catch @panic("OOM");
    const fallback_toml_module = b.createModule(.{
        .root_source_file = b.addWriteFiles().add("fallback_toml.zig", fallback_toml_src),
        .target   = target,
        .optimize = optimize,
    });

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
    maybeStrip(root_module, optimize); // wireModules handles all other modules

    const exe = b.addExecutable(.{ .name = "hana", .root_module = root_module });

    var all_modules = std.StringHashMap(ModuleEntry).init(b.allocator);

    discoverModules(b, ROOT_DIR, target, optimize, b.allocator, &all_modules) catch |err| {
        std.debug.print("Fatal: failed to discover modules: {}\n", .{err});
        std.process.exit(1);
    };

    for (layout_modules) |name| {
        build_options.addOption(bool, b.fmt("has_{s}", .{name}), all_modules.contains(name));
    }

    // has_any_segment is computed here so it can be passed to linkSystemLibraries.
    var has_any_segment = false;
    for (segment_modules) |name| {
        const present = all_modules.contains(name);
        build_options.addOption(bool, b.fmt("has_{s}", .{name}), present);
        has_any_segment = has_any_segment or present;
    }
    build_options.addOption(bool, "has_any_segment", has_any_segment);

    const build_options_module = build_options.createModule();

    root_module.addImport("build_options", build_options_module);
    root_module.addImport("fallback_toml", fallback_toml_module);

    wireModules(b, root_module, &all_modules,
        build_options_module, fallback_toml_module,
        optimize, b.allocator);

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

const ModuleEntry = struct {
    module:      *std.Build.Module,
    source_path: []const u8,
};

fn maybeStrip(mod: *std.Build.Module, optimize: std.builtin.OptimizeMode) void {
    if (optimize == .ReleaseFast or optimize == .ReleaseSmall) mod.strip = true;
}

fn wireModules(
    b:                    *std.Build,
    root:                 *std.Build.Module,
    all_modules:          *std.StringHashMap(ModuleEntry),
    build_options_module: *std.Build.Module,
    fallback_toml_module: *std.Build.Module,
    optimize:             std.builtin.OptimizeMode,
    allocator:            std.mem.Allocator,
) void {
    var iter = all_modules.iterator();
    while (iter.next()) |entry| {
        const mod = entry.value_ptr.module;
        maybeStrip(mod, optimize);

        mod.addImport("build_options", build_options_module);
        mod.addImport("fallback_toml", fallback_toml_module);

        const imports = findModuleImports(b, allocator, entry.value_ptr.source_path, all_modules);
        for (imports) |name| {
            const dep = all_modules.get(name) orelse continue;
            mod.addImport(name, dep.module);
        }

        root.addImport(entry.key_ptr.*, mod);
    }
}

// Scans a module's root file for @import calls and returns names that match a
// discovered module. Only the root file is scanned — imports in sub-files must
// be added manually in wireModules if needed.
// Note: cannot distinguish @import inside a string literal from a real one;
// spurious edges are harmless.
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

        // Skip @imports on comment lines (//, ///, //!).
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

fn fileExists(b: *std.Build, path: []const u8) bool {
    _ = b.build_root.handle.statFile(b.graph.io, path, .{}) catch return false;
    return true;
}

/// Escapes a byte string for embedding in a Zig double-quoted string literal.
/// Handles \, ", \n, \r, \t; uses \xNN for other non-printable bytes.
fn zigEscape(allocator: std.mem.Allocator, input: []const u8) []const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (input) |c| switch (c) {
        '\\' => out.appendSlice(allocator, "\\\\") catch @panic("OOM"),
        '"'  => out.appendSlice(allocator, "\\\"") catch @panic("OOM"),
        '\n' => out.appendSlice(allocator, "\\n")  catch @panic("OOM"),
        '\r' => out.appendSlice(allocator, "\\r")  catch @panic("OOM"),
        '\t' => out.appendSlice(allocator, "\\t")  catch @panic("OOM"),
        ' '...'"' - 1, '"' + 1...'\\' - 1, '\\' + 1...'~'
            => out.append(allocator, c)            catch @panic("OOM"),
            else => {
                var buf: [4]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "\\x{x:0>2}", .{c}) catch unreachable;
                out.appendSlice(allocator, s) catch @panic("OOM");
            },
        };
    return out.toOwnedSlice(allocator) catch @panic("OOM");
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
            if (std.mem.startsWith(u8, entry.name, ".")) continue; // skip hidden dirs

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
        if (std.mem.eql(u8, entry.name, "main.zig")) continue; // executable root, not a module

        const name     = std.fs.path.stem(entry.name);
        const rel_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });

        if (all_modules.contains(name)) {
            std.debug.print("Error: module name collision: '{s}' (at {s})\n", .{ name, rel_path });
            return error.ModuleNameCollision;
        }

        try all_modules.put(try allocator.dupe(u8, name), .{
            .module = b.createModule(.{
                .root_source_file = b.path(rel_path),
                .target   = target,
                .optimize = optimize,
            }),
            .source_path = rel_path,
        });
    }
}
