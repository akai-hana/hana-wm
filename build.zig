//! hana's build configuration
//! Includes module auto-discovery and sub-system gating.
//!
//! Module auto-discovery:
//! - Every `.zig` file under `src/` (except `main.zig`) becomes an import
//!   by the key of its own file stem.
//! - Optional subsystems are exposed as `has_<filestem>` build-options,
//!   so source code can import import build options and branch at comptime.
//!
//! Sub-system gating:
//! - If a subsystem directory lacks its own entry-point/central file
//!   (`<dir>/<dir>.zig`), the entire dir is skipped over during discovery.

const std     = @import("std");
const builtin = @import("builtin");

// Compile-time version guard — must be top-level so it fires before the
// compiler analyses any function body that uses master-only APIs.
comptime {
    if (builtin.zig_version.pre == null) @compileError(
        \\!!! Hana requires Zig's master branch. !!!
        \\
        \\# If your package manager doesn't ship it, you can try ZVM's easy installer:
        \\curl https://raw.githubusercontent.com/tristanisham/zvm/master/install.sh | bash
        \\# And then install Zig's master branch:
        \\zvm i master
        \\
    );
}

// Configuration

const source_root = "src/";

const optional_subsystems = [_][]const u8{
    // core/
    "scale",
    "debug",

    // window/
    "fullscreen",
    "minimize",
    "workspaces",

    // tiling/
    "tiling",
        "layouts",
            "master",
            "monocle",
            "grid",
            "fibonacci",

    // bar/
    "bar",
        "tags",
        "layout",
        "variants",
        "title",
            "carousel",
            "prompt",
                "vim",
        "clock",
};

// Entry point

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    // Fallback config
    const fallback_toml     = readFallbackToml(b);
    // Attempt to embed `config/fallback.toml` at build time
    const fallback_toml_mod = buildFallbackTomlModule(b, fallback_toml, target, optimize);

    // Build options
    const build_opts = b.addOptions();
    build_opts.addOption(bool, "enable_debug_logging", optimize == .Debug);
    build_opts.addOption(bool, "has_fallback_toml",    fallback_toml != null);

    // Module discovery
    var discovery = Module.DiscoveryContext.run(b, target, optimize, source_root) catch |err| {
        std.debug.print("Fatal: module discovery failed: {}\n", .{err});
        std.process.exit(1);
    };

    // Emit one `has_<n>` build option per optional subsystem.
    for (optional_subsystems) |sys| {
        const is_present = discovery.modules.contains(sys);
        build_opts.addOption(bool, b.fmt("has_{s}", .{sys}), is_present);
    }
    const has_bar = discovery.modules.contains("bar");

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
    Module.wireAll(root_mod, &discovery.modules, shared_ctx);
    SystemLibraries.link(root_mod, has_bar);

    // Artifact & steps
    const exe = b.addExecutable(.{ .name = "hana", .root_module = root_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run",   "Run hana").dependOn(&run_cmd.step);
    b.step("check", "Type-check without installing").dependOn(&exe.step);
}

// Shared context

/// Shared artefacts injected into every discovered module.
const SharedBuildContext = struct {
    build_opts:    *std.Build.Module,
    fallback_toml: *std.Build.Module,
    optimize:      std.builtin.OptimizeMode,
};

// Helpers

/// Reads `config/fallback.toml` from the build root.
///
/// Uses a build-lifetime arena so no explicit free is needed.
fn readFallbackToml(b: *std.Build) ?[]const u8 {
    return b.build_root.handle.readFileAlloc(
        b.graph.io,
        "config/fallback.toml",
        b.allocator,
        .limited(1024 * 1024), // Memory limit just in case
    ) catch null;
}

/// Generates a synthetic Zig module exposing fallback TOML data.
/// 
/// Exposes a `content` slice containing either the provided TOML or an empty string. 
/// Generating this at build-time allows consumers to safely import the content 
/// unconditionally, avoiding messy `@embedFile` checks in the source code.
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
///
/// Has no effect on Debug or ReleaseSafe builds.
fn stripIfRelease(mod: *std.Build.Module, optimize: std.builtin.OptimizeMode) void {
    switch (optimize) {
        .ReleaseFast, .ReleaseSmall => mod.strip = true,
        else => {},
    }
}

// Module namespace discovery & wiring

/// Namespace that owns all logic related to module discovery and wiring.
///
/// Grouped here so the entry point (`build`) stays at a high level of abstraction.
const Module = struct {

    /// Mutable state threaded through the entire discovery pass.
    ///
    /// Grouping it here means discoverAll and registerModule take only the arguments
    /// that actually vary per call, and future additions touch zero function signatures.
    const DiscoveryContext = struct {
        b:            *std.Build,
        target:       std.Build.ResolvedTarget,
        optimize:     std.builtin.OptimizeMode,
        modules:      std.StringHashMap(*std.Build.Module),
        source_paths: std.StringHashMap([]const u8),
        /// Built once from `optional_subsystems` for O(1) gating lookups.
        gated_names:  std.StringHashMap(void),

        fn init(
            b:        *std.Build,
            target:   std.Build.ResolvedTarget,
            optimize: std.builtin.OptimizeMode,
        ) !DiscoveryContext {
            var gated_names = std.StringHashMap(void).init(b.allocator);
            for (optional_subsystems) |name|
                try gated_names.put(name, {});

            return .{
                .b            = b,
                .target       = target,
                .optimize     = optimize,
                .modules      = std.StringHashMap(*std.Build.Module).init(b.allocator),
                .source_paths = std.StringHashMap([]const u8).init(b.allocator),
                .gated_names  = gated_names,
            };
        }

        fn run(
            b:        *std.Build,
            target:   std.Build.ResolvedTarget,
            optimize: std.builtin.OptimizeMode,
            dir_path: []const u8,
        ) !DiscoveryContext {
            var ctx = try init(b, target, optimize);
            try ctx.discoverAll(dir_path);
            return ctx;
        }

        /// Recursively walks `dir_path`, registers every `.zig` file as a named module
        /// (except `main.zig`), and skips gated-out subsystem directories.
        fn discoverAll(ctx: *DiscoveryContext, dir_path: []const u8) !void {
            const b = ctx.b;
            var dir = try b.build_root.handle.openDir(b.graph.io, dir_path, .{ .iterate = true });
            defer dir.close(b.graph.io);

            var iter = dir.iterate();
            while (try iter.next(b.graph.io)) |entry| {
                switch (entry.kind) {
                    .directory => {
                        if (isHiddenDirectory(entry.name)) continue;
                        if (isGatedOut(ctx, dir_path, entry.name)) continue;

                        const subdir_path = try std.fs.path.join(b.allocator, &.{ dir_path, entry.name });
                        try ctx.discoverAll(subdir_path);
                    },

                    .file => {
                        if (!isZigSource(entry.name)) continue;
                        if (isEntryPoint(entry.name))  continue;
                        try ctx.registerModule(dir_path, entry.name);
                    },

                    else => {},
                }
            }
        }

        /// Registers a new module.
        ///
        /// Handles collisions if found.
        fn registerModule(ctx: *DiscoveryContext, dir_path: []const u8, filename: []const u8) !void {
            const b        = ctx.b;
            const stem     = std.fs.path.stem(filename);
            const rel_path = try std.fs.path.join(b.allocator, &.{ dir_path, filename });

            if (ctx.source_paths.get(stem)) |existing_path| {
                std.debug.print(
                    "Error: module name collision '{s}'\n  first:  {s}\n  second: {s}\n",
                    .{ stem, existing_path, rel_path },
                );
                return error.ModuleNameCollision;
            }

            const owned_stem = try b.allocator.dupe(u8, stem);
            try ctx.source_paths.put(owned_stem, rel_path);
            try ctx.modules.put(owned_stem, b.createModule(.{
                .root_source_file = b.path(rel_path),
                .target   = ctx.target,
                .optimize = ctx.optimize,
            }));
        }
 
        /// Checks whether a sub-system is gated out or not.
        ///
        /// A subsystem's directory is gated out when it appears in `optional_subsystems`
        /// and yet its conventional entry point (`<dir>/<n>/<n>.zig`) is absent.
        /// This lets users opt out of a feature by simply deleting its central/entry file in charge.
        fn isGatedOut(ctx: *const DiscoveryContext, parent: []const u8, dir_name: []const u8) bool {
            if (!ctx.gated_names.contains(dir_name)) return false;

            const b          = ctx.b;
            const entry_path = b.pathJoin(&.{ parent, dir_name, b.fmt("{s}.zig", .{dir_name}) });
            return !pathExists(b, entry_path);
        }
    };

    /// Wires up all discovered modules together.
    ///
    /// Injects discovered modules into `root`, then cross-wires all modules with each other.
    /// Because unused imports are elided by the compiler, this blanket approach keeps the
    /// build script simple without affecting compile time or binary size.
    fn wireAll(
        root: *std.Build.Module,
        all:  *std.StringHashMap(*std.Build.Module),
        ctx:  SharedBuildContext,
    ) void {
        var outer = all.iterator();
        while (outer.next()) |entry| {
            const mod  = entry.value_ptr.*;
            const name = entry.key_ptr.*;

            stripIfRelease(mod, ctx.optimize);
            mod.addImport("build_options", ctx.build_opts);
            mod.addImport("fallback_toml", ctx.fallback_toml);

            // Cross-wire modules
            // Gives current module access to every other module.
            var inner = all.iterator();
            while (inner.next()) |dep| {
                if (!std.mem.eql(u8, dep.key_ptr.*, name))
                    mod.addImport(dep.key_ptr.*, dep.value_ptr.*);
            }

            root.addImport(name, mod);
        }
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

/// Namespace that owns all system library linkage.
///
/// Helps keep `build()` clean.
const SystemLibraries = struct {
    /// Links system libraries depended by hana.
    ///
    /// Cairo/Pango/GLib are only linked when at least one bar segment exists,
    /// in case the user wants to use hana without its bar.
    fn link(root: *std.Build.Module, has_bar: bool) void {
        linkXcb(root);
        if (has_bar) linkCairoPango(root);
    }

    // Core libraries
    fn linkXcb(root: *std.Build.Module) void {
        root.linkSystemLibrary("xcb-keysyms",   .{});
        root.linkSystemLibrary("xkbcommon-x11", .{});
        root.linkSystemLibrary("xcb-cursor",    .{}); // Makes hana's root window respect custom cursor settings.
    }

    // Bar libraries
    fn linkCairoPango(root: *std.Build.Module) void {
        root.linkSystemLibrary("pangocairo-1.0", .{});
    }
};
