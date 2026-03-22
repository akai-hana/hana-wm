//! Build configuration for Hana window manager

const std     = @import("std");
const builtin = @import("builtin");

// FIX #13 — Minimum Zig version guard.
// Several APIs used below (b.graph.io, b.build_root.handle.statFile, etc.)
// were introduced in 0.14.0.  Fail loudly here instead of producing a
// confusing "field not found" or "no member" error deeper in the build.
comptime {
    const min = std.SemanticVersion{ .major = 0, .minor = 14, .patch = 0 };
    if (builtin.zig_version.order(min) == .lt)
        @compileError("Zig 0.14.0 or newer is required to build Hana");
}

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
        .name        = "scale",
        .entry_point = ROOT_DIR ++ "core/scale.zig",
    },
    .{
        .name        = "tiling",
        .entry_point = ROOT_DIR ++ "window/modules/tiling/tiling.zig",
        .gate_dir    = "tiling",
    },
    .{
        .name        = "layouts",
        .entry_point = ROOT_DIR ++ "window/modules/tiling/layouts.zig",
    },
    .{
        .name        = "fullscreen",
        .entry_point = ROOT_DIR ++ "window/modules/fullscreen/fullscreen.zig",
        .gate_dir    = "fullscreen",
    },
    .{
        .name        = "minimize",
        .entry_point = ROOT_DIR ++ "window/modules/minimize.zig",
    },
    .{
        .name        = "workspaces",
        .entry_point = ROOT_DIR ++ "window/modules/workspaces.zig",
    },
};
// FIX #1 — Removed the duplicate "Add new optional subsystems here" comment
//           that previously appeared here after the closing brace.

// FIX #4 / #5 — Declarative lists for layout and bar-segment module names.
// Adding a new layout or segment now only requires adding its name here;
// the has_<name> build_option and has_any_segment flag are derived automatically.
const layout_modules = [_][]const u8{
    "master", "monocle", "grid", "fibonacci",
};

const segment_modules = [_][]const u8{
    "tags", "layout", "variants", "title", "clock", "status",
};

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_debug_logging", optimize == .Debug);

    // FIX #14 — b.build_root.handle / b.graph.io note:
    // We use b.build_root.handle (rather than std.fs.cwd()) so that paths are
    // always resolved relative to the build root, regardless of the working
    // directory from which `zig build` is invoked.  b.graph.io is the I/O
    // interface required by the build-root handle; it is an internal Zig build
    // API that may move across master builds — if it does, update these call
    // sites together.
    //
    // FIX #2 / #3 — Allocation note:
    // b.allocator is an arena that lives for the entire build invocation.
    // Intermediate allocations (fallback_toml, zigEscape output, fallback_toml_src)
    // are intentionally not freed individually; the arena reclaims them all at once
    // when the build process exits.
    const fallback_toml = b.build_root.handle.readFileAlloc(
        b.graph.io, "config/fallback.toml", b.allocator, .limited(1024 * 1024),
    ) catch null;
    build_options.addOption(bool, "has_fallback_toml", fallback_toml != null);

    // Store the toml content in a dedicated module rather than build_options.
    // build_options cannot store []const u8 without triggering a std.fmt compile
    // error on newer Zig master (pointer formatting requires an explicit specifier).
    // std.zig.fmtEscapes has also moved across master builds, so we use a small
    // local helper that is stable regardless of stdlib churn.
    const fallback_toml_src = std.fmt.allocPrint(b.allocator,
        "pub const content: []const u8 = \"{s}\";",
        .{zigEscape(b.allocator, fallback_toml orelse "")},
    ) catch @panic("OOM");
    const fallback_toml_module = b.createModule(.{
        .root_source_file = b.addWriteFiles().add("fallback_toml.zig", fallback_toml_src),
        .target   = target,
        .optimize = optimize,
    });

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

    // FIX #10 — strip is now applied via a shared helper so the rule is
    //           defined once.  wireModules calls maybeStrip for all discovered
    //           modules; we call it here for root_module which bypasses that loop.
    maybeStrip(root_module, optimize);

    const exe = b.addExecutable(.{ .name = "hana", .root_module = root_module });

    var all_modules = std.StringHashMap(ModuleEntry).init(b.allocator);

    discoverModules(b, ROOT_DIR, target, optimize, b.allocator, &all_modules) catch |err| {
        std.debug.print("Fatal: failed to discover modules: {}\n", .{err});
        std.process.exit(1);
    };

    // FIX #4 — Layout flags derived from the layout_modules array.
    // To add a new layout, append its module stem to layout_modules above.
    for (layout_modules) |name| {
        build_options.addOption(bool, b.fmt("has_{s}", .{name}), all_modules.contains(name));
    }

    // FIX #5 — Bar segment flags and has_any_segment derived from segment_modules.
    // has_any_segment is used both here (build_options) and by linkSystemLibraries,
    // so it is computed in a single pass to avoid the names being listed twice.
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

    // FIX #11 — check step: builds the executable without installing it.
    // zls and other LSP/tooling rely on this step for fast type-checking.
    const check = b.step("check", "Type-check without installing");
    check.dependOn(&exe.step);

    // FIX #12 — test step: currently a no-op placeholder.
    // Wire in `b.addTest(...)` calls here as test suites are added to the project.
    _ = b.step("test", "Run unit tests");
}

const ModuleEntry = struct {
    module:      *std.Build.Module,
    source_path: []const u8,
};

// FIX #10 — Shared strip helper.  Any module targeting ReleaseFast or
// ReleaseSmall has debug info stripped.  Centralising the rule here means
// it only needs to be updated in one place.
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
        maybeStrip(mod, optimize); // FIX #10 — use shared helper

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

// FIX #7 — Limitation: only the module's root .zig file is scanned.
// If a module's root file delegates work to sub-files via relative @import
// paths, and those sub-files in turn @import other discovered modules, those
// secondary imports will NOT be wired in automatically.  If you see "no module
// named '...'" errors in non-root files, add the missing import explicitly in
// wireModules or restructure so the root re-exports the dependency.
//
// FIX #8 — Caveat: the scanner cannot distinguish @import inside a string
// literal (e.g. const s = "@import(\"foo\")") from a real import, so such
// strings will produce a spurious, harmless dependency edge if "foo" is a
// known module.  This is unlikely to cause real problems but worth noting.
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
        // startsWith("//") covers //, ///, and //! — all Zig line-comment forms.
        // Block comments (/* ... */) are not handled; they are rare in practice.
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

/// Escape a byte string for embedding as a Zig double-quoted string literal.
/// Handles \, ", \n, \r, \t and uses \xNN for anything else non-printable.
/// Avoids depending on std.zig.fmtEscapes, which has moved across master builds.
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
            // FIX #9 — Use startsWith rather than entry.name[0] to safely skip
            // hidden directories (the index access would panic on an empty name).
            if (std.mem.startsWith(u8, entry.name, ".")) continue;

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
        // main.zig is the executable root, not a reusable module; skip it.
        if (std.mem.eql(u8, entry.name, "main.zig")) continue;

        // FIX #6 — Note on optional-subsystem entry points:
        // Files such as bar/bar.zig or input/input.zig are both the entry point
        // for their optional subsystem *and* a regular discovered module.  This
        // is intentional: the optional-subsystem machinery gates whether the
        // containing directory is traversed at all; once inside, the file is
        // treated like any other module and wired in by wireModules.
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
