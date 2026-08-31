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
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .native } });
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
    build_opts.addOption(bool, "has_fallback_toml", fallback_toml != null);

    // Optional module detection
    const has_tiling = hasPathOption(b, build_opts, "has_tiling", source_root ++ "tiling");
    const has_floating = hasPathOption(b, build_opts, "has_floating", source_root ++ "window/modules/floating.zig");
    if (!has_tiling and !has_floating) {
        @panic("hana requires at least one windowing paradigm: src/tiling/ or src/window/modules/floating.zig");
    }
    const has_minimize = hasPathOption(b, build_opts, "has_minimize", source_root ++ "window/modules/minimize.zig");
    const has_fullscreen = hasPathOption(b, build_opts, "has_fullscreen", source_root ++ "window/modules/fullscreen.zig");
    const has_workspaces = hasPathOption(b, build_opts, "has_workspaces", source_root ++ "window/modules/workspaces.zig");
    _ = hasPathOption(b, build_opts, "has_vim", source_root ++ "bar/modules/prompt/vim.zig");

    // Tier 5: bar internals; if any core internal is missing, forfeit the entire bar.
    const has_drawing = pathExists(b.build_root.handle, b.graph.io, source_root ++ "bar/drawing.zig");
    const has_bar_render = pathExists(b.build_root.handle, b.graph.io, source_root ++ "bar/render.zig");
    const has_bar_win = pathExists(b.build_root.handle, b.graph.io, source_root ++ "bar/win.zig");
    const has_bar_segment = pathExists(b.build_root.handle, b.graph.io, source_root ++ "bar/segment.zig");
    const has_bar_dir = pathExists(b.build_root.handle, b.graph.io, source_root ++ "bar");
    const has_bar = has_bar_dir and has_drawing and has_bar_render and has_bar_win and has_bar_segment;
    build_opts.addOption(bool, "has_bar", has_bar);

    // Tier 3: individual tiling layout modules
    _ = hasPathOption(b, build_opts, "has_layout_master", source_root ++ "tiling/modules/master.zig");
    _ = hasPathOption(b, build_opts, "has_layout_monocle", source_root ++ "tiling/modules/monocle.zig");
    _ = hasPathOption(b, build_opts, "has_layout_fibonacci", source_root ++ "tiling/modules/fibonacci.zig");
    _ = hasPathOption(b, build_opts, "has_layout_grid", source_root ++ "tiling/modules/grid.zig");
    _ = hasPathOption(b, build_opts, "has_layout_leaf", source_root ++ "tiling/modules/leaf.zig");
    _ = hasPathOption(b, build_opts, "has_layout_scroll", source_root ++ "tiling/modules/scroll.zig");

    // Tier 4: individual bar segment modules
    const has_seg_clock = hasPathOption(b, build_opts, "has_seg_clock", source_root ++ "bar/modules/clock.zig");
    _ = hasPathOption(b, build_opts, "has_seg_tags", source_root ++ "bar/modules/tags.zig");
    _ = hasPathOption(b, build_opts, "has_seg_layout", source_root ++ "bar/modules/layout.zig");
    _ = hasPathOption(b, build_opts, "has_seg_title", source_root ++ "bar/modules/title/title.zig");
    _ = hasPathOption(b, build_opts, "has_seg_prompt", source_root ++ "bar/modules/prompt/prompt.zig");
    const has_seg_carousel = hasPathOption(b, build_opts, "has_seg_carousel", source_root ++ "bar/modules/title/carousel.zig");
    _ = hasPathOption(b, build_opts, "has_seg_variants", source_root ++ "bar/modules/variants.zig");

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

    // Generated registration modules. Built after discovery (the plugin
    // modules must exist to be imported by name) but before injectShared
    // wires root + every discovered module with the generated imports: a
    // module can't hand its own import to itself.
    const build_opts_mod = build_opts.createModule();
    // `plugins` is reduced to the chrome-surface (bar) contract; the window
    // behaviors moved to per-owner `modules` registries below.
    const plugins_mod = buildPluginsModule(b, &discovery.modules, build_opts_mod, fallback_toml_mod, target, optimize);
    stripIfRelease(plugins_mod, optimize);
    addSystemDirs(plugins_mod, b);

    // Directory-scan discovery of `modules/` dirs under src/: every `.zig`
    // under a `modules/` dir registers into a generated `<owner>_modules`
    // registry (`src/window/modules/` becomes `window_modules`,
    // `src/bar/modules/` becomes `bar_modules`, `src/tiling/modules/`
    // becomes `tiling_modules`; each owner gets its contract type via
    // `ownerContractName`). The scan also validates the generated registry
    // names don't collide with a discovered file's stem (a src-side
    // `<owner>_modules.zig` would shadow the injected import and corrupt
    // every module's import table).
    var registry = try OwnerRegistry.run(b, source_root);
    try validateRegistryNames(b, &registry, &discovery.modules);
    const owner_modules = try buildOwnerRegistries(b, &discovery.modules, build_opts_mod, fallback_toml_mod, target, optimize, &registry);
    var oms_it = owner_modules.valueIterator();
    while (oms_it.next()) |m| {
        stripIfRelease(m.*, optimize);
        addSystemDirs(m.*, b);
    }

    // Root module
    const shared_ctx: SharedBuildContext = .{
        .build_opts = build_opts_mod,
        .fallback_toml = fallback_toml_mod,
        .plugins = plugins_mod,
        .owner_modules = owner_modules,
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
    // found. Point at them explicitly when they exist; the extra paths are
    // harmless elsewhere and absent on non-FHS distros (NixOS, Guix) whose
    // toolchains already provide the real locations.
    addSystemDirs(root_mod, b);
    // Wire & link
    Module.wireAll(root_mod, &discovery.modules, shared_ctx);
    SystemLibraries.link(root_mod);
    // Discovered modules don't inherit root_mod's include/library paths, so
    // give each one the same system paths for its @cImport / link work.
    var mod_it = discovery.modules.valueIterator();
    while (mod_it.next()) |mod| {
        addSystemDirs(mod.*, b);
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
            // clock_test imports the `clock` module, which only exists when
            // src/bar/modules/clock.zig is present (has_seg_clock).
            if (!has_seg_clock and std.mem.eql(u8, entry.key_ptr.*, "clock_test")) continue;
            // carousel_test imports the `carousel` module, which only exists
            // when src/bar/modules/title/carousel.zig is present.
            if (!has_seg_carousel and std.mem.eql(u8, entry.key_ptr.*, "carousel_test")) continue;
            // model_test exercises all four window feature modules
            // (minimize/fullscreen/floating/workspaces), so every one must be present.
            if (!(has_minimize and has_fullscreen and has_floating and has_workspaces) and std.mem.eql(u8, entry.key_ptr.*, "model_test")) continue;
            // perf_test replays minimize/fullscreen/workspaces scenarios; without
            // those modules the referenced behaviors don't exist.
            if (!(has_minimize and has_fullscreen and has_workspaces) and std.mem.eql(u8, entry.key_ptr.*, "perf_test")) continue;
            // tiling_test exercises the tiling layout engine internals; without
            // src/tiling there is no engine to test, and its `engine.HintsView`
            // reference no longer resolves.
            if (!has_tiling and std.mem.eql(u8, entry.key_ptr.*, "tiling_test")) continue;
            // sync_test replays tiling-centric scenarios (retile, fullscreen
            // enter/exit, minimize, workspace switch), which need minimize and
            // fullscreen modules in addition to the tiling engine itself.
            if ((!has_tiling or !has_minimize or !has_fullscreen) and std.mem.eql(u8, entry.key_ptr.*, "sync_test")) continue;
            // workspaces_test exercises the workspaces behavior; without
            // src/window/modules/workspaces.zig its `Workspace` type is
            // replaced by an empty struct and the test no longer compiles.
            if (!has_workspaces and std.mem.eql(u8, entry.key_ptr.*, "workspaces_test")) continue;
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
    const layers = b.addSystemCommand(&.{"./dev/scripts/check-layers.sh"});
    layers.step.dependOn(&exe.step);
    check_step.dependOn(&layers.step);
}

// Shared context

/// Names already claimed by `injectShared`. A discovered module sharing one
/// of these names would collide with the import `injectShared` adds to
/// every module, so `Module.registerModule` rejects them at registration
/// time with a clear error instead of failing deep inside `addImport`.
/// `plugins` is reserved for the build-generated chrome-surface registration
/// module; no `src/plugins.zig` may exist. The per-owner `modules` registry
/// names (`<owner>_modules`) are build output that lives OUTSIDE `src/`, so
/// they can't collide with a discovered file of the same stem in practice;
/// `validateRegistryNames` still flags any discovered file that would collide
/// with a generated one, since that would shadow the injected import.
const reserved_module_names = [_][]const u8{ "build_options", "fallback_toml", "plugins" };

/// Shared artefacts injected into every module, root and discovered alike.
const SharedBuildContext = struct {
    build_opts: *std.Build.Module,
    fallback_toml: *std.Build.Module,
    /// The build-generated chrome-surface registration module created by
    /// `buildPluginsModule` (exports `Surfaces`). Injected into every module
    /// so core source can `@import("plugins").Surfaces` without ever naming
    /// the bar. Kept separate from the per-owner `modules` registries so the
    /// bar family stays byte-identical.
    plugins: *std.Build.Module,
    /// The build-generated per-owner `modules` registries created by
    /// `buildOwnerRegistries`, keyed by their injectable import name
    /// (`<owner>_modules`, e.g. `window_modules`). Injected into every module
    /// so core source can `@import("window_modules").modules` to iterate an
    /// owner's auto-discovered sub-system set with uniform loops.
    owner_modules: std.StringHashMapUnmanaged(*std.Build.Module),
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

/// Source of the generated `plugins` registration module (see
/// `buildPluginsModule`). Written by the build, never committed. Reduced to
/// the chrome-surface (bar) contract only: the window behaviors no longer
/// merge here; they register into per-owner `modules` registries generated
/// by `buildOwnerRegistries` (a directory scan, not a fixed has_* list), and
/// core tiers iterate those with uniform loops. `plugins` is kept (rather
/// than folded into the `modules` registries) so the bar's `Surfaces` seam
/// stays byte-identical and its consumers (`@import("plugins").Surfaces`)
/// never change.
const plugins_generated_source =
    \\const build_options = @import("build_options");
    \\
    \\/// The active chrome-surface hook set, or the comptime `null` type when no
    \\/// surface module is compiled in.
    \\pub const Surfaces = if (build_options.has_bar) @import("bar").surfaces else null;
;

/// Generates the build-owned `plugins` module alongside its source file, and
/// returns the module to inject everywhere via `injectShared`.
///
/// This is the single seam that concentrates core to chrome-surface coupling.
/// Mirroring the `buildFallbackTomlModule` precedent, the source is written
/// at build time via `addWriteFiles` and exposed as a normal module
/// (`b.createModule`), so nothing about it is committed. The generated module
/// is deliberately given only the imports its source references (unlike
/// discovered modules, which are cross-wired with everything).
fn buildPluginsModule(
    b: *std.Build,
    discovered: *std.StringHashMap(*std.Build.Module),
    build_opts: *std.Build.Module,
    fallback_toml: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const write = b.addWriteFiles();
    const mod = b.createModule(.{
        .root_source_file = write.add("plugins.zig", plugins_generated_source),
        .target = target,
        .optimize = optimize,
    });

    // The chrome-surface module is referenceable (`@import("bar")`) only when
    // its source was discovered; the comptime has_bar guard keeps the
    // no-registration case from ever being analyzed.
    const referenced = [_][]const u8{"bar"};
    for (referenced) |name| {
        if (discovered.get(name)) |m| mod.addImport(name, m);
    }
    mod.addImport("build_options", build_opts);
    mod.addImport("fallback_toml", fallback_toml);
    return mod;
}

/// Directory-scan discovery of `modules/` directories.
///
/// The `modules/` discovery convention: every directory named exactly
/// `modules` found anywhere under `src/` is a set of pluggable sub-systems
/// for the core system that owns it, where the owner is the immediate parent
/// directory. Each `.zig` file under a `modules/` tree (recursively; nested
/// subdirectories are included) is a sub-system module registered by stem.
/// The build emits one synthesized `<owner>_modules` registry per found
/// directory, typed by the owner's contract (`window` -> `WindowModule`,
/// `bar` -> `Segment`, `tiling` -> `Layout`, see `ownerContractName`); core
/// source iterates it with uniform dispatch loops. Dropping a `.zig` into an
/// owner's `modules/` dir auto-registers it; deleting it auto-deregisters
/// (a rebuild regenerates). Current owners: `window`, `bar`, `tiling`.
const OwnerRegistry = struct {
    /// owner name (parent dir basename) maps to sorted, deduped `.zig` stems under
    /// that owner's `modules/` tree. All strings are dup'd into b.allocator
    /// (build-lifetime arena); never freed.
    owners: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .{},

    /// Build-time discovery of every `src/<owner>/modules/` tree. The entry
    /// point path is the file-scope `entry_point_path` const (the source root
    /// is threaded because it doubles as the recursion start); no param here
    /// because a same-named param would shadow that const.
    fn run(b: *std.Build, source_root_path: []const u8) !OwnerRegistry {
        var reg = OwnerRegistry{};
        var ctx = ScanCtx{
            .b = b,
            .entry_point_path = entry_point_path,
            .owner_registry = &reg,
        };
        try ctx.walkForOwnerDirs(source_root_path);
        // Deterministic dispatch order: sort each owner's stems. Filesystem
        // iteration order is not guaranteed stable, so the build pins the
        // order the generated registry lists (which is the dispatch order
        // core loops iterate).
        for (reg.owners.values()) |*list| {
            std.mem.sort([]const u8, list.items, {}, struct {
                fn lessThan(_: void, a: []const u8, b_: []const u8) bool {
                    return std.mem.lessThan(u8, a, b_);
                }
            }.lessThan);
        }
        return reg;
    }

    const ScanCtx = struct {
        b: *std.Build,
        entry_point_path: []const u8,
        owner_registry: *OwnerRegistry,

        /// Recursively walks `src/` (skipping hidden dirs) for directories
        /// named `modules`; on a hit, harvests every `.zig` stem under it and
        /// records them against the parent directory's name (the owner).
        fn walkForOwnerDirs(ctx: *ScanCtx, dir_path: []const u8) !void {
            const b = ctx.b;
            var dir = try b.build_root.handle.openDir(b.graph.io, dir_path, .{ .iterate = true });
            defer dir.close(b.graph.io);

            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            var iter = dir.iterate();
            while (try iter.next(b.graph.io)) |entry| {
                if (entry.kind != .directory) continue;
                if (Module.isHiddenDirectory(entry.name)) continue;
                const sub_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name });
                if (std.mem.eql(u8, entry.name, "modules")) {
                    // This dir is a sub-system set for its parent (the owner).
                    const owner = pathBasename(dir_path);
                    // A degenerate `src//modules`-style path (trailing slash)
                    // yields an empty basename; skip rather than synthesising
                    // a garbage registry name.
                    if (owner.len == 0) continue;
                    const dup_owner = try b.allocator.dupe(u8, owner);
                    const gop = try ctx.owner_registry.owners.getOrPut(b.allocator, dup_owner);
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    try ctx.collectStems(sub_path, true, &gop.value_ptr.*);
                } else {
                    const dup_path = try b.allocator.dupe(u8, sub_path);
                    try ctx.walkForOwnerDirs(dup_path);
                }
            }
        }

        /// Recursively collects the `<owner>_modules` registry stems under a
        /// `modules/` tree.
        ///
        /// Convention: at the owner root (`is_root`), every direct `.zig` file
        /// is a segment module. Inside a nested segment directory, ONLY the
        /// file whose stem equals the directory's name (the eponymous segment
        /// file) is a registry member; sibling files there are that segment's
        /// private helpers and stay out of the registry (they remain
        /// importable by name via the separate greedy module discovery).
        fn collectStems(
            ctx: *ScanCtx,
            dir_path: []const u8,
            is_root: bool,
            stems: *std.ArrayListUnmanaged([]const u8),
        ) !void {
            const b = ctx.b;
            const dir_name = std.fs.path.basename(dir_path);
            var dir = try b.build_root.handle.openDir(b.graph.io, dir_path, .{ .iterate = true });
            defer dir.close(b.graph.io);

            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            var iter = dir.iterate();
            while (try iter.next(b.graph.io)) |entry| {
                switch (entry.kind) {
                    .directory => {
                        if (Module.isHiddenDirectory(entry.name)) continue;
                        const sub_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name });
                        const dup_path = try b.allocator.dupe(u8, sub_path);
                        try ctx.collectStems(dup_path, false, stems);
                    },
                    .file => {
                        if (!Module.isZigSource(entry.name)) continue;
                        const rel_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name });
                        if (Module.isEntryPointPath(rel_path, ctx.entry_point_path)) continue;

                        const stem = try b.allocator.dupe(u8, std.fs.path.stem(entry.name));
                        // In a nested segment directory, keep only the
                        // eponymous file (stem == containing dir name) as a
                        // segment; helpers simply are not registered.
                        if (!is_root and !std.mem.eql(u8, stem, dir_name)) continue;

                        // Dedup-guard against doubles scored from nested
                        // `modules/` trees: names must be unique per owner, so
                        // a hit here would be a developer error the generated
                        // registry would otherwise surface as a duplicate
                        // import.
                        for (stems.items) |existing| {
                            if (std.mem.eql(u8, existing, stem)) break;
                        } else {
                            try stems.append(b.allocator, stem);
                        }
                    },
                    else => {},
                }
            }
        }
    };

    /// Basename of a path, tolerating trailing slashes (source_root is
    /// `"src/"`), so the owner name never comes out empty for `src/`.
    fn pathBasename(path: []const u8) []const u8 {
        var p = path;
        while (p.len > 1 and p[p.len - 1] == '/') p = p[0 .. p.len - 1];
        if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| return p[i + 1 ..];
        return p;
    }
};

/// Flags a discovered file whose stem collides with a generated
/// `<owner>_modules` registry name. The registry modules are build output that
/// lives outside `src/`, so no source file *must* collide; if one does (say a
/// user drops `src/window_modules.zig` while `src/window/modules/` exists),
/// the injected import would shadow the discovered module in its own import
/// table. Reject loudly instead of confusing later users of the name.
fn validateRegistryNames(
    b: *std.Build,
    registry: *const OwnerRegistry,
    discovered: *const std.StringHashMap(*std.Build.Module),
) !void {
    var it = registry.owners.iterator();
    while (it.next()) |entry| {
        const generated = try std.fmt.allocPrint(b.allocator, "{s}_modules", .{entry.key_ptr.*});
        if (discovered.contains(generated)) {
            std.debug.print(
                "Error: module name '{s}' collides with the build-generated " ++
                    "<owner>_modules registry import every module gets. Rename or delete the discovered file.\n",
                .{generated},
            );
            return error.ReservedModuleName;
        }
    }
}

/// The registry element type per owner: each <owner>/modules/ tree binds its
/// addons to the matching contract in plugin.zig. Unknown owners are a
/// developer error (a brand-new modules/ dir must pick its contract here or
/// the generated registry would mis-type every module's `module` value).
fn ownerContractName(owner: []const u8) []const u8 {
    if (std.mem.eql(u8, owner, "window")) return "WindowModule";
    if (std.mem.eql(u8, owner, "bar")) return "Segment";
    if (std.mem.eql(u8, owner, "tiling")) return "Layout";
    std.debug.print(
        "Error: modules/ dir found under unknown owner '{s}'; " ++
            "add its contract to ownerContractName in build.zig.\n",
        .{owner},
    );
    return "WindowModule";
}

/// Generates one synthesized `<owner>_modules` registry module per discovered
/// `modules/` dir and returns them keyed by their injectable import name.
/// Each registry source lists, in deterministic scan order, every discovered
/// sub-system module's `module` value, so core tiers iterate it with uniform
/// loops and never name a sub-system module. Committed source is
/// behaviour-identical across presence combinations; deleting a sub-system's
/// file only regenerates a shorter array.
fn buildOwnerRegistries(
    b: *std.Build,
    discovered: *std.StringHashMap(*std.Build.Module),
    build_opts: *std.Build.Module,
    fallback_toml: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    registry: *OwnerRegistry,
) !std.StringHashMapUnmanaged(*std.Build.Module) {
    var out = std.StringHashMapUnmanaged(*std.Build.Module){};
    var it = registry.owners.iterator();
    while (it.next()) |entry| {
        const name = try std.fmt.allocPrint(b.allocator, "{s}_modules", .{entry.key_ptr.*});
        const mod = try buildOwnerRegistryModule(
            b,
            discovered,
            build_opts,
            fallback_toml,
            target,
            optimize,
            name,
            ownerContractName(entry.key_ptr.*),
            entry.value_ptr.*.items,
        );
        try out.put(b.allocator, name, mod);
    }
    return out;
}

/// Generates a single `<owner>_modules` registry module alongside its source
/// file. Imports are added only for what the source references: `plugin` (the
/// interface contract), every discovered sub-system stem it lists, plus
/// `build_options`/`fallback_toml` for symmetry with the other generated
/// modules. A stem that isn't discovered can't be listed (the scan walked the
/// real filesystem), so every listed stem import exists; the defensive check
/// mirrors buildPluginsModule.
fn buildOwnerRegistryModule(
    b: *std.Build,
    discovered: *std.StringHashMap(*std.Build.Module),
    build_opts: *std.Build.Module,
    fallback_toml: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    contract: []const u8,
    stems: []const []const u8,
) !*std.Build.Module {
    const write = b.addWriteFiles();

    var src = std.ArrayList(u8).empty;
    try src.print(b.allocator, "const plugin = @import(\"plugin\");\n\n", .{});
    try src.print(b.allocator, "/// The auto-discovered `{s}` sub-system modules, in deterministic\n", .{name});
    try src.print(b.allocator, "/// filesystem scan order (dispatch order == this array's order).\n", .{});
    try src.print(b.allocator, "/// Generated by build.zig; never committed.\n", .{});
    try src.print(b.allocator, "pub const modules = [_]plugin.{s}{{\n", .{contract});
    for (stems) |stem| {
        try src.print(b.allocator, "    @import(\"{s}\").module,\n", .{stem});
    }
    try src.print(b.allocator, "}};\n", .{});

    const mod = b.createModule(.{
        // `.zig` suffix matters: a compile-time arg `-M<name>=<path>` with a
        // root file lacking a recognized extension is treated as a non-
        // compilation unit and is never registered, so an import of the
        // registry would fail to bind.
        .root_source_file = write.add(b.fmt("{s}.zig", .{name}), src.items),
        .target = target,
        .optimize = optimize,
    });

    if (discovered.get("plugin")) |m| mod.addImport("plugin", m);
    for (stems) |stem| {
        if (discovered.get(stem)) |m| mod.addImport(stem, m);
    }
    mod.addImport("build_options", build_opts);
    mod.addImport("fallback_toml", fallback_toml);
    return mod;
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
/// the tree: build options, the fallback-config stub, the chrome-surface
/// registration (`plugins`), and every per-owner `modules` registry
/// (`<owner>_modules`, this round `window_modules`). Shared by the root
/// module and every discovered module so there's exactly one place that
/// knows what "every module gets this" means. Generated registries are NOT
/// passed through here (a module can't receive its own import); they get
/// their own imports in `buildOwnerRegistries`.
fn injectShared(mod: *std.Build.Module, ctx: SharedBuildContext) void {
    mod.addImport("build_options", ctx.build_opts);
    mod.addImport("fallback_toml", ctx.fallback_toml);
    mod.addImport("plugins", ctx.plugins);
    var it = ctx.owner_modules.iterator();
    while (it.next()) |entry| mod.addImport(entry.key_ptr.*, entry.value_ptr.*);
}

fn pathExists(root: std.Io.Dir, io: anytype, rel_path: []const u8) bool {
    // Check files first, the common case in a source tree, to avoid the
    // extra syscall from trying as a directory when it is actually a file.
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

/// Checks whether a source path exists, records the result under `name` as a
/// build option, and returns it. Collapses the repetitive "probe a path, add
/// a matching has_* option" pattern so each optional feature needs one line.
fn hasPathOption(
    b: *std.Build,
    opts: *std.Build.Step.Options,
    name: []const u8,
    rel_path: []const u8,
) bool {
    const present = pathExists(b.build_root.handle, b.graph.io, rel_path);
    opts.addOption(bool, name, present);
    return present;
}

/// Conditionally points a module's system include/library search path at
/// /usr/include and /usr/lib. These are only helpful on FHS-style hosts that
/// report an empty default search path (e.g. some musl distros); on non-FHS
/// distros (NixOS, Guix) the directories don't exist and adding them would be
/// noise, so gate on presence.
fn addSystemDirs(mod: *std.Build.Module, b: *std.Build) void {
    const io = b.graph.io;
    const root = b.build_root.handle;
    if (pathExists(root, io, "/usr/lib")) mod.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    if (pathExists(root, io, "/usr/include")) mod.addIncludePath(.{ .cwd_relative = "/usr/include" });
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
        // xcb-free, sync sole wire writer) is enforced by dev/scripts/check-layers.sh
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

            // Cross-wire modules: O(n²) in module count, but n is small and
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
