//! Build configuration for the Hana window manager.
//!
//! Module discovery is fully automatic: every `.zig` file under `src/` (except
//! `main.zig`) becomes a named import whose key is the file stem.  Optional
//! subsystems listed in `optional_subsystems` are exposed as `has_<name>`
//! build-options so source code can `@import("build_options")` and branch at
//! comptime.
//!
//! Gating: if a subsystem directory lacks its own entry-point file
//! (`<dir>/<dir>.zig`), the entire directory is skipped during discovery.

const std     = @import("std");
const builtin = @import("builtin");

// Configuration

const source_root = "src/";

/// Describes a subsystem whose presence in the build is optional.
/// Bar *segments* (is_segment = true) additionally contribute to the
/// `has_any_segment` flag that gates Cairo/Pango linkage.
const OptionalSubsystem = struct {
    name:       []const u8,
    /// True when this subsystem renders a visual segment on the status bar.
    is_segment: bool = false,
};

/// Add an entry here to expose a new optional subsystem, layout, or bar segment
/// to the rest of the build system.  No other changes are required.
const optional_subsystems = [_]OptionalSubsystem{
    // core/modules/
    .{ .name = "scale" },
    .{ .name = "debug" },

    // window/modules/
    .{ .name = "fullscreen" },
    .{ .name = "minimize"   },
    .{ .name = "workspaces" },

    // window/modules/tiling/
    .{ .name = "tiling"    },
    .{ .name = "layouts"   },
    .{ .name = "master"    },
    .{ .name = "monocle"   },
    .{ .name = "grid"      },
    .{ .name = "fibonacci" },

    // bar/
    .{ .name = "bar" },

    // bar/modules/ (segments)
    .{ .name = "tags",     .is_segment = true },
    .{ .name = "layout",   .is_segment = true },
    .{ .name = "variants", .is_segment = true },
    .{ .name = "title",    .is_segment = true },
    .{ .name = "carousel", .is_segment = true },
    .{ .name = "clock",    .is_segment = true },

    // bar/modules/ (non-segment: replaces title as active segment) -----
    .{ .name = "prompt" },
};

// Entry point

pub fn build(b: *std.Build) void {
    requireMasterBranch();

    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    // Fallback config
    // Attempt to embed `config/fallback.toml` at build time so users who ship
    // without a config file still get sensible defaults.
    const fallback_toml = readFallbackToml(b);
    const fallback_toml_mod = buildFallbackTomlModule(b, fallback_toml, target, optimize);

    // Build options
    const build_opts = b.addOptions();
    build_opts.addOption(bool, "enable_debug_logging", optimize == .Debug);
    build_opts.addOption(bool, "has_fallback_toml",    fallback_toml != null);

    // Module discovery
    var discovered = std.StringHashMap(DiscoveredModule).init(b.allocator);
    Module.discoverAll(b, source_root, target, optimize, &discovered) catch |err| {
        std.debug.print("Fatal: module discovery failed: {}\n", .{err});
        std.process.exit(1);
    };

    // Emit one `has_<name>` build option per optional subsystem.
    var has_any_segment = false;
    for (optional_subsystems) |sys| {
        const is_present = discovered.contains(sys.name);
        build_opts.addOption(bool, b.fmt("has_{s}", .{sys.name}), is_present);
        if (sys.is_segment and is_present) has_any_segment = true;
    }
    build_opts.addOption(bool, "has_any_segment", has_any_segment);

    // Root module
    const shared_ctx: SharedBuildContext = .{
        .build_opts    = build_opts.createModule(),
        .fallback_toml = fallback_toml_mod,
        .optimize      = optimize,
    };

    const root_mod = b.createModule(.{
        .root_source_file = b.path(source_root ++ "core/main.zig"),
        .target    = target,
        .optimize  = optimize,
        .link_libc = true,
    });
    stripIfRelease(root_mod, optimize);
    root_mod.addImport("build_options", shared_ctx.build_opts);
    root_mod.addImport("fallback_toml", shared_ctx.fallback_toml);

    // Wire & link
    Module.wireAll(root_mod, &discovered, shared_ctx);
    SystemLibraries.link(root_mod, has_any_segment);

    // Artifact & steps
    const exe = b.addExecutable(.{ .name = "hana", .root_module = root_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run",   "Run hana").dependOn(&run_cmd.step);
    b.step("check", "Type-check without installing").dependOn(&exe.step);
    _ = b.step("test", "Run unit tests");
}

// Types

/// A Zig module that was found during directory traversal.
const DiscoveredModule = struct {
    module:      *std.Build.Module,
    source_path: []const u8,
};

/// Shared artefacts injected into every discovered module and the root module.
const SharedBuildContext = struct {
    build_opts:    *std.Build.Module,
    fallback_toml: *std.Build.Module,
    optimize:      std.builtin.OptimizeMode,
};

// Helpers — fallback TOML

/// Reads `config/fallback.toml` from the build root, or returns null if absent.
/// Uses the build-lifetime arena so no explicit free is needed.
fn readFallbackToml(b: *std.Build) ?[]const u8 {
    return b.build_root.handle.readFileAlloc(
        b.graph.io,
        "config/fallback.toml",
        b.allocator,
        .limited(1024 * 1024),
    ) catch null;
}

/// Produces a synthetic Zig module that exposes the TOML content (or an empty
/// slice) via `pub const content: []const u8`.  Using a generated module rather
/// than a raw `@embedFile` call lets the build script control whether the file
/// is embedded at all without adding an `if` into every consumer.
fn buildFallbackTomlModule(
    b:        *std.Build,
    content:  ?[]const u8,
    target:   std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const write = b.addWriteFiles();

    if (content) |toml| _ = write.add("fallback.toml", toml);

    const stub_source = if (content != null)
        \\pub const content: []const u8 = @embedFile("fallback.toml");
    else
        \\pub const content: []const u8 = "";
    ;

    return b.createModule(.{
        .root_source_file = write.add("fallback_toml.zig", stub_source),
        .target   = target,
        .optimize = optimize,
    });
}

// Helpers

/// Enables symbol stripping for release builds to reduce binary size.
/// Has no effect on Debug or ReleaseSafe builds.
fn stripIfRelease(mod: *std.Build.Module, optimize: std.builtin.OptimizeMode) void {
    switch (optimize) {
        .ReleaseFast, .ReleaseSmall => mod.strip = true,
        else => {},
    }
}

// Module namespace discovery & wiring

/// Namespace that owns all logic related to module discovery and wiring.
/// Grouped here so the entry point (`build`) stays at a high level of abstraction.
const Module = struct {

    /// Recursively walks `dir_path`, registers every `.zig` file (except
    /// `main.zig`) as a named module, and skips gated-out subsystem directories.
    fn discoverAll(
        b:          *std.Build,
        dir_path:   []const u8,
        target:     std.Build.ResolvedTarget,
        optimize:   std.builtin.OptimizeMode,
        out:        *std.StringHashMap(DiscoveredModule),
    ) !void {
        var dir = try b.build_root.handle.openDir(b.graph.io, dir_path, .{ .iterate = true });
        defer dir.close(b.graph.io);

        var iter = dir.iterate();
        while (try iter.next(b.graph.io)) |entry| {
            switch (entry.kind) {
                .directory => {
                    if (isHiddenDirectory(entry.name)) continue;
                    if (isGatedOut(b, dir_path, entry.name)) continue;

                    const subdir_path = try std.fs.path.join(b.allocator, &.{ dir_path, entry.name });
                    try discoverAll(b, subdir_path, target, optimize, out);
                },
                .file => {
                    if (!isZigSource(entry.name)) continue;
                    if (isEntryPoint(entry.name))  continue;
                    try registerModule(b, dir_path, entry.name, target, optimize, out);
                },
                else => {},
            }
        }
    }

    /// Injects every discovered module into `root` and cross-wires all modules
    /// with each other.  Because unused imports are elided by the compiler,
    /// this blanket approach keeps the build script simple without affecting
    /// compile time or binary size.
    fn wireAll(
        root: *std.Build.Module,
        all:  *std.StringHashMap(DiscoveredModule),
        ctx:  SharedBuildContext,
    ) void {
        var outer = all.iterator();
        while (outer.next()) |entry| {
            const mod  = entry.value_ptr.module;
            const name = entry.key_ptr.*;

            stripIfRelease(mod, ctx.optimize);
            mod.addImport("build_options", ctx.build_opts);
            mod.addImport("fallback_toml", ctx.fallback_toml);

            // Cross-wire: give this module access to every *other* module.
            var inner = all.iterator();
            while (inner.next()) |dep| {
                if (!std.mem.eql(u8, dep.key_ptr.*, name))
                    mod.addImport(dep.key_ptr.*, dep.value_ptr.module);
            }

            root.addImport(name, mod);
        }
    }

    // Private helpers

    fn registerModule(
        b:        *std.Build,
        dir_path: []const u8,
        filename: []const u8,
        target:   std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        out:      *std.StringHashMap(DiscoveredModule),
    ) !void {
        const stem     = std.fs.path.stem(filename);
        const rel_path = try std.fs.path.join(b.allocator, &.{ dir_path, filename });

        if (out.contains(stem)) {
            std.debug.print("Error: module name collision '{s}' (path: {s})\n", .{ stem, rel_path });
            return error.ModuleNameCollision;
        }

        try out.put(try b.allocator.dupe(u8, stem), .{
            .module = b.createModule(.{
                .root_source_file = b.path(rel_path),
                .target   = target,
                .optimize = optimize,
            }),
            .source_path = rel_path,
        });
    }

    /// A subsystem directory is gated out when it appears in `optional_subsystems`
    /// but its conventional entry point (`<dir>/<name>/<name>.zig`) is absent.
    /// This lets users opt out of a feature by simply deleting its entry file.
    fn isGatedOut(b: *std.Build, parent: []const u8, dir_name: []const u8) bool {
        for (optional_subsystems) |sys| {
            if (!std.mem.eql(u8, sys.name, dir_name)) continue;
            const entry_path = b.pathJoin(&.{ parent, dir_name, b.fmt("{s}.zig", .{dir_name}) });
            return !pathExists(b, entry_path);
        }
        return false;
    }

    fn pathExists(b: *std.Build, path: []const u8) bool {
        _ = b.build_root.handle.statFile(b.graph.io, path, .{}) catch return false;
        return true;
    }

    fn isHiddenDirectory(name: []const u8) bool {
        return std.mem.startsWith(u8, name, ".");
    }

    fn isZigSource(filename: []const u8) bool {
        return std.mem.endsWith(u8, filename, ".zig");
    }

    fn isEntryPoint(filename: []const u8) bool {
        return std.mem.eql(u8, filename, "main.zig");
    }
};

// System library linkage

/// Namespace that owns system library linkage to keep `build()` clean.
const SystemLibraries = struct {

    /// Links the system libraries required by Hana.
    /// Cairo/Pango and the GLib stack are only linked when at least one bar
    /// segment is present, keeping headless builds lean.
    fn link(root: *std.Build.Module, has_any_segment: bool) void {
        linkXcb(root);
        if (has_any_segment) linkCairoPango(root);
    }

    fn linkXcb(root: *std.Build.Module) void {
        root.linkSystemLibrary("X11",           .{});
        root.linkSystemLibrary("xcb",            .{});
        root.linkSystemLibrary("xcb-cursor",     .{});
        root.linkSystemLibrary("xcb-keysyms",    .{});
        root.linkSystemLibrary("xkbcommon",      .{});
        root.linkSystemLibrary("xkbcommon-x11",  .{});
    }

    fn linkCairoPango(root: *std.Build.Module) void {
        root.linkSystemLibrary("cairo",          .{});
        root.linkSystemLibrary("pangocairo-1.0", .{});
        root.linkSystemLibrary("pango-1.0",      .{});
        root.linkSystemLibrary("glib-2.0",       .{});
        root.linkSystemLibrary("gobject-2.0",    .{});
    }
};

// Compile-time guard

/// Aborts compilation with a friendly message when built against a stable Zig
/// release.  Hana uses APIs that are only available on the master branch.
fn requireMasterBranch() void {
    if (builtin.zig_version.pre == null) {
        @compileError(
            \\Hana requires Zig's master branch.
            \\If your package manager doesn't ship it, try ZVM:
            \\  curl https://raw.githubusercontent.com/tristanisham/zvm/master/install.sh | bash
        );
    }
}
