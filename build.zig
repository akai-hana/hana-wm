//! hana's build configuration
//! Includes module auto-discovery: every .zig file under src/ becomes a
//! named module, available to import from every other module.
//!
//! This script relies on newer, still-evolving parts of the standard
//! library (e.g. the Io-based filesystem calls below), so it requires a
//! recent Zig build. Rather than a comptime version guard here, declare the
//! minimum supported compiler via build.zig.zon's `minimum_zig_version`
//! field -- that's the version-manager-aware place for it today (read by
//! zvm, mise, vscode-zig, etc.).

const std = @import("std");

// Configuration
//
// Every path (and path-adjacent limit) this build script depends on,
// gathered in one place so they're easy to audit together instead of being
// scattered as inline literals.

const source_root = "src/";
const entry_point_path = source_root ++ "main.zig";
const fallback_toml_path = "config/fallback.toml";
const max_fallback_toml_bytes = 1024 * 1024; // Memory limit just in case.

// Entry point

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    if (target.result.os.tag != .linux) {
        std.debug.print(
            "Fatal: hana only supports Linux (it links against xcb, xkbcommon-x11, and pango/cairo).\n",
            .{},
        );
        return error.UnsupportedTarget;
    }

    // Fallback config
    const fallback_toml = readFallbackToml(b);
    // Attempt to embed `config/fallback.toml` at build time
    const fallback_toml_mod = buildFallbackTomlModule(b, fallback_toml, target, optimize);

    // Build options
    const build_opts = b.addOptions();
    build_opts.addOption(bool, "enable_debug_logging", optimize == .Debug);
    build_opts.addOption(bool, "has_fallback_toml", fallback_toml != null);

    // Optional module detection
    const has_bar_dir = pathExists(b.build_root.handle, b.graph.io, source_root ++ "bar");
    const has_tiling = pathExists(b.build_root.handle, b.graph.io, source_root ++ "tiling");
    const has_floating = pathExists(b.build_root.handle, b.graph.io, source_root ++ "window/behaviors/floating.zig");
    const has_fullscreen = pathExists(b.build_root.handle, b.graph.io, source_root ++ "window/behaviors/fullscreen.zig");
    const has_minimize = pathExists(b.build_root.handle, b.graph.io, source_root ++ "window/behaviors/minimize.zig");
    const has_workspaces = pathExists(b.build_root.handle, b.graph.io, source_root ++ "window/behaviors/workspaces.zig");
    const has_vim = pathExists(b.build_root.handle, b.graph.io, source_root ++ "bar/segments/prompt/vim.zig");

    // Tier 5: bar internals — if any core internal is missing, forfeit the entire bar.
    const has_drawing = pathExists(b.build_root.handle, b.graph.io, source_root ++ "bar/drawing.zig");
    const has_bar_render = pathExists(b.build_root.handle, b.graph.io, source_root ++ "bar/render.zig");
    const has_bar_win = pathExists(b.build_root.handle, b.graph.io, source_root ++ "bar/win.zig");
    const has_bar_segment = pathExists(b.build_root.handle, b.graph.io, source_root ++ "bar/segments/segment.zig");
    const has_bar = has_bar_dir and has_drawing and has_bar_render and has_bar_win and has_bar_segment;

    // Tier 3: individual tiling layout modules
    const has_layout_master = pathExists(b.build_root.handle, b.graph.io, source_root ++ "tiling/layouts/master.zig");
    const has_layout_monocle = pathExists(b.build_root.handle, b.graph.io, source_root ++ "tiling/layouts/monocle.zig");
    const has_layout_fibonacci = pathExists(b.build_root.handle, b.graph.io, source_root ++ "tiling/layouts/fibonacci.zig");
    const has_layout_grid = pathExists(b.build_root.handle, b.graph.io, source_root ++ "tiling/layouts/grid.zig");
    const has_layout_leaf = pathExists(b.build_root.handle, b.graph.io, source_root ++ "tiling/layouts/leaf.zig");
    const has_layout_scroll = pathExists(b.build_root.handle, b.graph.io, source_root ++ "tiling/layouts/scroll.zig");

    // Tier 4: individual bar segment modules
    const has_seg_clock = pathExists(b.build_root.handle, b.graph.io, source_root ++ "bar/segments/clock.zig");
    const has_seg_tags = pathExists(b.build_root.handle, b.graph.io, source_root ++ "bar/segments/tags.zig");
    const has_seg_layout = pathExists(b.build_root.handle, b.graph.io, source_root ++ "bar/segments/layout/layout.zig");
    const has_seg_title = pathExists(b.build_root.handle, b.graph.io, source_root ++ "bar/segments/title/title.zig");
    const has_seg_prompt = pathExists(b.build_root.handle, b.graph.io, source_root ++ "bar/segments/prompt/prompt.zig");
    const has_seg_carousel = pathExists(b.build_root.handle, b.graph.io, source_root ++ "bar/segments/title/carousel.zig");
    const has_seg_variants = pathExists(b.build_root.handle, b.graph.io, source_root ++ "bar/segments/layout/variants.zig");

    build_opts.addOption(bool, "has_bar", has_bar);
    build_opts.addOption(bool, "has_tiling", has_tiling);
    build_opts.addOption(bool, "has_floating", has_floating);
    build_opts.addOption(bool, "has_fullscreen", has_fullscreen);
    build_opts.addOption(bool, "has_minimize", has_minimize);
    build_opts.addOption(bool, "has_workspaces", has_workspaces);
    build_opts.addOption(bool, "has_vim", has_vim);
    build_opts.addOption(bool, "has_layout_master", has_layout_master);
    build_opts.addOption(bool, "has_layout_monocle", has_layout_monocle);
    build_opts.addOption(bool, "has_layout_fibonacci", has_layout_fibonacci);
    build_opts.addOption(bool, "has_layout_grid", has_layout_grid);
    build_opts.addOption(bool, "has_layout_leaf", has_layout_leaf);
    build_opts.addOption(bool, "has_layout_scroll", has_layout_scroll);
    build_opts.addOption(bool, "has_seg_clock", has_seg_clock);
    build_opts.addOption(bool, "has_seg_tags", has_seg_tags);
    build_opts.addOption(bool, "has_seg_layout", has_seg_layout);
    build_opts.addOption(bool, "has_seg_title", has_seg_title);
    build_opts.addOption(bool, "has_seg_prompt", has_seg_prompt);
    build_opts.addOption(bool, "has_seg_carousel", has_seg_carousel);
    build_opts.addOption(bool, "has_seg_variants", has_seg_variants);

    // Module discovery
    var discovery = try Module.DiscoveryContext.run(b, target, optimize, source_root, entry_point_path);
    // schema_test drives the full load pipeline (config.loadConfig), which
    // reaches fallback.zig's terminal detection -> std.c.getenv and the
    // keybind parser's xkb_keysym_from_name; give that test module libc and
    // the same system libraries as the root module.
    if (discovery.modules.get("schema_test")) |m| {
        m.link_libc = true;
        SystemLibraries.link(m);
    }
    // Register null vim fallback when vim.zig is absent but bar is present.
    // When bar itself is removed, prompt is also gone so no vim stub is needed.
    // When the prompt directory is removed, null_vim.zig is also gone.
    const null_vim_path = source_root ++ "bar/segments/prompt/null_vim.zig";
    const has_null_vim_file = pathExists(b.build_root.handle, b.graph.io, null_vim_path);
    if (has_bar and !has_vim and has_null_vim_file) {
        const owned_name = try b.allocator.dupe(u8, "vim");
        try discovery.source_paths.put(owned_name, null_vim_path);
        try discovery.modules.put(owned_name, b.createModule(.{
                .root_source_file = b.path(null_vim_path),
                .target = target,
                .optimize = optimize,
            }));
        // Prevent null_vim.zig from also being registered as "null_vim"
        // via auto-discovery — it's only needed as the "vim" stub here.
        _ = discovery.modules.remove("null_vim");
        _ = discovery.source_paths.remove("null_vim");
    }

    // Root module
    const shared_ctx: SharedBuildContext = .{
        .build_opts = build_opts.createModule(),
        .fallback_toml = fallback_toml_mod,
        .optimize = optimize,
    };

    const root_mod = b.createModule(.{
        .root_source_file = b.path(entry_point_path),

        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    stripIfRelease(root_mod, optimize);

    // Some hosts (e.g. musl-based distros) report an empty default system
    // include/library search path, so headers and libraries under /usr aren't
    // found. Point at them explicitly; the extra paths are harmless elsewhere.
    root_mod.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    root_mod.addIncludePath(.{ .cwd_relative = "/usr/include" });

    // Wire & link
    Module.wireAll(root_mod, &discovery.modules, shared_ctx);
    SystemLibraries.link(root_mod);
    // Discovered modules don't inherit root_mod's include/library paths, so
    // give each one the same system paths for its @cImport / link work.
    var mod_it = discovery.modules.valueIterator();
    while (mod_it.next()) |mod| {
        mod.*.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
        mod.*.addIncludePath(.{ .cwd_relative = "/usr/include" });
    }

    // Unit tests for the reworked architecture layers (src/test/*.zig):
    // every discovered module named *_test.zig becomes a `zig build test`
    // run. Discovered modules are cross-wired with all others, so a test
    // file's named imports
    // (e.g. model, utils) resolve exactly as they do in production builds --
    // standalone `zig test <file>` cannot resolve them (module-root escape),
    // which is why tests go through the build system.
    const unit_test_step = b.step("test", "Run unit tests");
    {
        var test_it = discovery.modules.iterator();
        while (test_it.next()) |entry| {
            if (!std.mem.endsWith(u8, entry.key_ptr.*, "_test")) continue;
            const t = b.addTest(.{ .root_module = entry.value_ptr.* });
            unit_test_step.dependOn(&b.addRunArtifact(t).step);
        }
    }

    // Artifact & steps
    const exe = b.addExecutable(.{ .name = "hana", .root_module = root_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run hana").dependOn(&run_cmd.step);
    // Layer guards (REARCHITECTURE_PLAN.md §13 / WP7): `zig build check`
    // type-checks AND enforces the sync-owned wire rules.
    const check_step = b.step("check", "Type-check + layer guards");
    check_step.dependOn(&exe.step);
    const layers = b.addSystemCommand(&.{ "./src/test/check-layers.sh" });
    layers.step.dependOn(&exe.step);
    check_step.dependOn(&layers.step);
}

// Shared context

/// Names already claimed by `injectShared`. A discovered module sharing one
/// of these names would collide with the import `injectShared` adds to
/// every module, so `Module.registerModule` rejects them at registration
/// time with a clear error instead of failing deep inside `addImport`.
const reserved_module_names = [_][]const u8{ "build_options", "fallback_toml" };

/// Shared artefacts injected into every module -- root and discovered alike.
const SharedBuildContext = struct {
    build_opts: *std.Build.Module,
    fallback_toml: *std.Build.Module,
    optimize: std.builtin.OptimizeMode,
};

// Helpers

/// Reads the fallback TOML config (`fallback_toml_path`) from the build root.
///
/// Uses a build-lifetime arena so no explicit free is needed. A missing file
/// is expected -- the fallback config is optional -- and treated as "no
/// fallback". Any other error (permissions, I/O, etc.) is surfaced as a
/// warning instead of being silently swallowed, so a real problem doesn't
/// quietly degrade the build.
fn readFallbackToml(b: *std.Build) ?[]const u8 {
    return b.build_root.handle.readFileAlloc(
        b.graph.io,
        fallback_toml_path,
        b.allocator,
        .limited(max_fallback_toml_bytes),
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => {
            std.debug.print("Warning: couldn't read {s}: {}\n", .{ fallback_toml_path, err });
            return null;
        },
    };
}

/// Generates a synthetic Zig module exposing fallback TOML data.
///
/// Exposes a `content` slice containing either the provided TOML or an empty string.
/// Generating this at build-time allows consumers to safely import the content
/// unconditionally, avoiding messy `@embedFile` checks in the source code.
fn buildFallbackTomlModule(
    b: *std.Build,
    content: ?[]const u8,
    target: std.Build.ResolvedTarget,
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
        .target = target,
        .optimize = optimize,
    });
}

/// Enables symbol stripping for release builds to reduce binary size.
///
/// Has no effect on Debug or ReleaseSafe builds.
fn stripIfRelease(mod: *std.Build.Module, optimize: std.builtin.OptimizeMode) void {
    switch (optimize) {
        .ReleaseFast, .ReleaseSmall => mod.strip = true,
        else => {},
    }
}

/// Injects the artefacts every module needs, regardless of where it lives in
/// the tree: build options and the fallback-config stub. Shared by the root
/// module and every discovered module so there's exactly one place that
/// knows what "every module gets this" means.
fn injectShared(mod: *std.Build.Module, ctx: SharedBuildContext) void {
    mod.addImport("build_options", ctx.build_opts);
    mod.addImport("fallback_toml", ctx.fallback_toml);
}

fn pathExists(root: std.Io.Dir, io: anytype, rel_path: []const u8) bool {
    // Check files first — the common case in a source tree — to avoid the
    // extra syscall from trying as a directory when it's actually a file.
    if (root.openFile(io, rel_path, .{})) |*f| {
        f.close(io);
        return true;
    } else |_| {}
    if (root.openDir(io, rel_path, .{})) |*dir| {
        dir.close(io);
        return true;
    } else |_| {}
    return false;
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
        b: *std.Build,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        entry_point_path: []const u8,
        // Neither map below is explicitly torn down: both they and their
        // duped keys live in b.allocator, which is an arena scoped to the
        // whole build, so their lifetime already matches the process's.
        modules: std.StringHashMap(*std.Build.Module),
        source_paths: std.StringHashMap([]const u8),

        fn init(
            b: *std.Build,
            target: std.Build.ResolvedTarget,
            optimize: std.builtin.OptimizeMode,
            entry_point: []const u8,
        ) DiscoveryContext {
            return .{
                .b = b,
                .target = target,
                .optimize = optimize,
                .entry_point_path = entry_point,
                .modules = std.StringHashMap(*std.Build.Module).init(b.allocator),
                .source_paths = std.StringHashMap([]const u8).init(b.allocator),
            };
        }

        fn run(
            b: *std.Build,
            target: std.Build.ResolvedTarget,
            optimize: std.builtin.OptimizeMode,
            dir_path: []const u8,
            entry_point: []const u8,
        ) !DiscoveryContext {
            var ctx = init(b, target, optimize, entry_point);
            try ctx.discoverAll(dir_path);
            return ctx;
        }

        /// Recursively walks `dir_path` and registers every `.zig` file as a
        /// named module, except the entry point itself (`ctx.entry_point_path`).
        fn discoverAll(ctx: *DiscoveryContext, dir_path: []const u8) !void {
            const b = ctx.b;
            var dir = try b.build_root.handle.openDir(b.graph.io, dir_path, .{ .iterate = true });
            defer dir.close(b.graph.io);

            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            var iter = dir.iterate();
            while (try iter.next(b.graph.io)) |entry| {
                switch (entry.kind) {
                    .directory => {
                        if (isHiddenDirectory(entry.name)) continue;

                        const subdir_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name });
                        try ctx.discoverAll(b.allocator.dupe(u8, subdir_path) catch unreachable);
                    },

                    .file => {
                        if (!isZigSource(entry.name)) continue;

                        const rel_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name });
                        if (isEntryPointPath(rel_path, ctx.entry_point_path)) continue;

                        try ctx.registerModule(b.allocator.dupe(u8, rel_path) catch unreachable);
                    },

                    else => {},
                }
            }
        }

        /// Registers a new module.
        ///
        /// Rejects reserved names (see `reserved_module_names`) and handles
        /// collisions between discovered modules if found.
        fn registerModule(ctx: *DiscoveryContext, rel_path: []const u8) !void {
            const b = ctx.b;
            const stem = std.fs.path.stem(std.fs.path.basename(rel_path));

            for (reserved_module_names) |reserved| {
                if (std.mem.eql(u8, stem, reserved)) {
                    std.debug.print(
                        "Error: module name '{s}' ({s}) is reserved -- it collides with the " ++
                            "import every module gets automatically. Rename the file.\n",
                        .{ stem, rel_path },
                    );
                    return error.ReservedModuleName;
                }
            }

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
                .target = ctx.target,
                .optimize = ctx.optimize,
            }));
        }
    };

    /// Wires up all discovered modules together.
    ///
    /// Injects shared imports into `root` itself, then into every discovered
    /// module, before cross-wiring all discovered modules with each other and
    /// exposing them to `root`. This gives every module access to every other
    /// module by name; because unused imports are elided by the compiler,
    /// this blanket approach keeps the build script simple without affecting
    /// compile time or binary size. Note that it also means there is
    /// currently no encapsulation boundary between modules -- worth
    /// revisiting with an opt-out mechanism if that coupling becomes a
    /// problem as the module tree grows. It also means every module's cached
    /// compilation is invalidated by a change to *any* module, not just the
    /// ones it actually uses -- a cost worth keeping in mind alongside compile
    /// time and binary size as the module count grows.
    fn wireAll(
        root: *std.Build.Module,
        all: *std.StringHashMap(*std.Build.Module),
        ctx: SharedBuildContext,
    ) void {
        // NOTE(I-1): Cross-wiring is blanket O(n²). Layer purity (model/tiling
        // xcb-free, sync sole wire writer) is enforced by src/test/check-layers.sh
        // at zig build check time, NOT at the module level. If a module accidentally
        // imports a forbidden dependency, the build succeeds but check-layers catches
        // the xcb leak. Future improvement: add per-layer import assertions.
        injectShared(root, ctx);

        var outer = all.iterator();
        while (outer.next()) |entry| {
            const mod = entry.value_ptr.*;
            const name = entry.key_ptr.*;

            stripIfRelease(mod, ctx.optimize);
            injectShared(mod, ctx);

            // Cross-wire modules — O(n²) in module count, but n is small and
            // comptime-eligible. Skip wiring if the import already exists to
            // avoid redundant table updates.
            var inner = all.iterator();
            while (inner.next()) |dep| {
                if (!std.mem.eql(u8, dep.key_ptr.*, name) and !mod.import_table.contains(dep.key_ptr.*))
                    mod.addImport(dep.key_ptr.*, dep.value_ptr.*);
            }

            root.addImport(name, mod);
        }
    }

    fn isHiddenDirectory(name: []const u8) bool {
        return std.mem.startsWith(u8, name, ".");
    }

    fn isZigSource(filename: []const u8) bool {
        return std.mem.endsWith(u8, filename, ".zig");
    }

    /// Compares a discovered path against the entry-point path component-wise
    /// rather than byte-wise.
    ///
    /// `rel_path` is produced by `std.fs.path.join`, which joins using the
    /// host's native separator; `entry_point_path` is a POSIX-style literal
    /// defined above. On POSIX hosts the two happen to use the same
    /// separator already, but comparing components keeps this correct on
    /// any host regardless.
    fn isEntryPointPath(rel_path: []const u8, entry_point: []const u8) bool {
        return std.mem.eql(u8, rel_path, entry_point);
    }
};

// System library linkage

/// Namespace that owns all system library linkage.
///
/// Helps keep `build()` clean.
const SystemLibraries = struct {
    /// Links system libraries depended on by hana.
    fn link(root: *std.Build.Module) void {
        linkXcb(root);
        linkCairoPango(root);
    }

    // Core libraries
    fn linkXcb(root: *std.Build.Module) void {
        root.linkSystemLibrary("xcb-keysyms", .{});
        root.linkSystemLibrary("xkbcommon-x11", .{});
        root.linkSystemLibrary("xcb-cursor", .{}); // Makes hana's root window respect custom cursor settings.
        root.linkSystemLibrary("xcb-randr", .{}); // Monitor refresh-rate detection for the carousel.
    }

    // Bar libraries
    fn linkCairoPango(root: *std.Build.Module) void {
        root.linkSystemLibrary("pangocairo-1.0", .{});
    }
};
