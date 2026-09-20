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
    build_opts.addOption(bool, "profile_key", b.option(bool, "profile-key", "Instrument the key dispatch path to log receive->action latency") orelse false);
    // Latency/benchmark tests print their timings and run their full loops
    // only when `-Dbench` is passed; the default suite keeps them as cheap
    // smoke runs so a passing `zig build test` never writes to stderr (the
    // build runner flags any test stderr as `failed command:` even on success).
    build_opts.addOption(bool, "bench", b.option(bool, "bench", "Run latency/benchmark tests with full iteration counts and timing output (opt-in; off by default)") orelse false);

    // Module discovery — runs before has_* probes so file-existence flags can
    // be derived from the discovered module set instead of re-probing the
    // filesystem.
    var discovery = try Module.DiscoveryContext.run(b, target, optimize, source_root, entry_point_path);

    // Optional module detection — file-based has_* flags are derived from
    // discovery.modules (which already walked src/) rather than re-probing
    // the filesystem. Directory and compound checks still use pathExists.
    const has_tiling = pathExists(b.build_root.handle, b.graph.io, source_root ++ "tiling");
    build_opts.addOption(bool, "has_tiling", has_tiling);
    const has_floating = discovery.modules.contains("floating");
    build_opts.addOption(bool, "has_floating", has_floating);
    if (!has_tiling and !has_floating) {
        @panic("hana requires at least one windowing paradigm: src/tiling/ or src/window/modules/floating.zig");
    }
    const has_minimize = discovery.modules.contains("minimize");
    build_opts.addOption(bool, "has_minimize", has_minimize);
    const has_fullscreen = discovery.modules.contains("fullscreen");
    build_opts.addOption(bool, "has_fullscreen", has_fullscreen);
    const has_workspaces = discovery.modules.contains("workspaces");
    build_opts.addOption(bool, "has_workspaces", has_workspaces);

    // Tier 5: bar internals; if any core internal is missing, forfeit the entire bar.
    const has_drawing = discovery.modules.contains("drawing");
    const has_bar_win = discovery.modules.contains("win");
    const has_bar_segment = discovery.modules.contains("segment");
    const has_bar_dir = pathExists(b.build_root.handle, b.graph.io, source_root ++ "bar");
    const has_bar = has_bar_dir and has_drawing and has_bar_win and has_bar_segment;
    build_opts.addOption(bool, "has_bar", has_bar);

    // Segment presence flags are consumed only by the test gate table below;
    // no Zig source reads them, so they are NOT published as build options.
    const has_seg_clock = discovery.modules.contains("clock");
    const has_seg_carousel = discovery.modules.contains("carousel");
    const has_seg_prompt = discovery.modules.contains("prompt");
    const has_seg_systatus = discovery.modules.contains("systatus");
    const has_seg_brightness = discovery.modules.contains("brightness");

    // The vim-modal prompt engine: its presence gates the engine test; the
    // engine is a prompt addon, so its tests also require the host package.
    const has_vim = discovery.modules.contains("vim");

    // Remaining has_* options: derived from the discovered module set.
    const optional_features = [_]struct { option: []const u8, stem: []const u8 }{
        .{ .option = "has_layout_scroll", .stem = "scroll" },
    };
    for (optional_features) |feature| {
        build_opts.addOption(bool, feature.option, discovery.modules.contains(feature.stem));
    }

    // Generated registration modules. Built after discovery (the plugin
    // modules must exist to be imported by name) but before injectShared
    // wires root + every discovered module with the generated imports: a
    // module can't hand its own import to itself.
    // /usr probe memoization: host-invariant within a build, so run once
    // instead of per finalizeModule call.
    const has_usr: UsrDirs = .{
        .lib = pathExists(b.build_root.handle, b.graph.io, "/usr/lib"),
        .include = pathExists(b.build_root.handle, b.graph.io, "/usr/include"),
    };

    const build_opts_mod = build_opts.createModule();
    // `plugins` is reduced to the chrome-surface (bar) contract; the window
    // behaviors moved to per-owner `modules` registries below.
    const plugins_mod = buildPluginsModule(b, &discovery.modules, build_opts_mod, target, optimize);
    finalizeModule(plugins_mod, optimize, has_usr);

    // Owner-registry discovery: `modules/` dirs found during the single src/
    // walk above populate per-owner stem lists, which are sorted here for
    // deterministic dispatch order. The registry must be fully populated
    // BEFORE `buildOwnerRegistries` is called (DFS visit order satisfies this
    // since discovery runs at build.zig:54 before buildOwnerRegistries at 134).
    var registry = try OwnerRegistry.run(&discovery);
    try validateRegistryNames(b, &registry, &discovery.modules);
    // Contract names are read from the modules' own `pub const module`
    // declarations (typed or via segdraw), never from a hand-written table.
    try deriveOwnerContracts(b, &discovery.source_paths, &registry);
    // Precompute each package's bound-sub list (siblings self-declaring the
    // binding, sorted alphabetically) BEFORE either consumer needs it: every
    // generated `<package>_subs` registry is one such list, and the
    // `segmentFor(i)` entries a `bar_segments` package contributes to
    // `bar_modules` index the SAME sorted list (`i` == `subs[i]`), so the two
    // orderings can never drift from each other.
    var bound_subs = std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)){};
    for (sub_registry_specs) |spec| {
        _ = try boundSubStems(b, &discovery, spec, &bound_subs);
    }
    var owner_modules = try buildOwnerRegistries(b, &discovery.modules, target, optimize, &registry, &bound_subs);
    // Package sub-addon registries (`<package>_subs`), generated from file
    // presence the same way the owner registries are, so a package core
    // (systatus, prompt, title, ...) never names one of its addon siblings
    // (readouts, the vim engine, the carousel). Dropping a sibling file only
    // regenerates a shorter array; nothing in the closed core is touched.
    // Injected through `owner_modules` so every module sees the generated
    // import like the other registries.
    for (sub_registry_specs) |spec| {
        const subs = bound_subs.getPtr(spec.package) orelse continue;
        const registry_name = try std.fmt.allocPrint(b.allocator, "{s}_subs", .{spec.package});
        try owner_modules.put(b.allocator, registry_name, try buildSubsRegistryModule(
            b,
            &discovery.modules,
            target,
            optimize,
            spec.package,
            spec.array,
            spec.binding,
            spec.contract,
            subs.items,
        ));
    }
    // Tiling-engine seam: a generated `tiling_seam` module that names the
    // tiling subsystem (or an inert empty struct when its dir is gone). The
    // core and input layers import the seam, never src/tiling/ by name, so
    // removing the tiling subsystem can't leave a named import dangling in
    // sync/pipeline/actions/input: the absent case is an empty type, only
    // ever reached through the same `has_tiling` gates that already guard
    // every registry-driven call site (mirroring `plugin.tiling_mods`).
    {
        var seam_src = std.ArrayList(u8).empty;
        try seam_src.appendSlice(b.allocator, "/// The tiling subsystem behind a build-time seam: core and input layers\n");
        try seam_src.appendSlice(b.allocator, "/// import this module, never src/tiling/ by name. When the tiling\n");
        try seam_src.appendSlice(b.allocator, "/// subsystem is absent the binding is an inert empty type (every member\n");
        try seam_src.appendSlice(b.allocator, "/// reference sits behind a build_options.has_tiling gate).\n");
        try seam_src.appendSlice(b.allocator, "/// Generated by build.zig; never committed.\n");
        try seam_src.appendSlice(b.allocator, "const build_options = @import(\"build_options\");\n\n");
        try seam_src.appendSlice(b.allocator, "pub const tiling = if (build_options.has_tiling) @import(\"tiling\") else struct {};\n");
        const seam_mod = makeGeneratedModule(b, target, optimize, "tiling_seam.zig", seam_src.items, &[_]Import{});
        seam_mod.addImport("build_options", build_opts_mod);
        if (discovery.modules.get("tiling")) |m| seam_mod.addImport("tiling", m);
        try owner_modules.put(b.allocator, "tiling_seam", seam_mod);
    }
    var oms_it = owner_modules.valueIterator();
    while (oms_it.next()) |m| {
        finalizeModule(m.*, optimize, has_usr);
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

    // Some hosts (e.g. musl-based distros) report an empty default system
    // include/library search path, so headers and libraries under /usr aren't
    // found. Point at them explicitly when they exist; the extra paths are
    // harmless elsewhere and absent on non-FHS distros (NixOS, Guix) whose
    // toolchains already provide the real locations.
    finalizeModule(root_mod, optimize, has_usr);
    // Wire & link
    try Module.wireAll(b, root_mod, &discovery.modules, &discovery.source_paths, shared_ctx);
    try SystemLibraries.loadLinks(b);
    SystemLibraries.link(root_mod);
    // Discovered modules don't inherit root_mod's include/library paths, so
    // give each one the same system paths for its @cImport / link work.
    var mod_it = discovery.modules.valueIterator();
    while (mod_it.next()) |mod| {
        // All discovered modules are compiled into the libc-linked `hana`
        // binary, and several of them call libc directly (fallback.zig's
        // getenv, window/floating's free). Precise-edge wiring no longer drags
        // in a link_libc test root, so declare libc explicitly per module.
        mod.*.link_libc = true;
        finalizeModule(mod.*, optimize, has_usr);
    }

    // Unit tests for the reworked architecture layers (src/test/**, grouped
    // by category: engine/, window/, bar/, config/, latency/):
    // every discovered module named *_test.zig becomes a `zig build test`
    // run. Discovered modules are cross-wired with all others, so a test
    // file's named imports
    // (e.g. model, utils) resolve exactly as they do in production builds --
    // standalone `zig test <file>` cannot resolve them (module-root escape),
    // which is why tests go through the build system.
    const unit_test_step = b.step("test", "Run unit tests");
    // X-gated integration tests connect to the same $DISPLAY; chain their run
    // steps so server-global input-focus assertions cannot race across the
    // parallel test processes.
    var x_gated_run: ?*std.Build.Step = null;
    // Tests whose modules only exist when their feature's source file is
    // present; the gate is the same has_* bool that guards the feature.
    // x_gated marks the X-dependent integration tests that serialize on the
    // shared display. Every test root links the full system-library set: with
    // precise edge wiring a test root no longer reaches the gated feature
    // roots that used to bleed their linkage into every test exe, so each
    // root declares its (potentially needed) libc-adjacent libraries itself.
    const test_gates = [_]struct { name: []const u8, gate: bool, x_gated: bool }{
        .{ .name = "actions_test", .gate = has_tiling, .x_gated = true },
        .{ .name = "focus_test", .gate = has_tiling, .x_gated = true },
        .{ .name = "pipeline_test", .gate = has_tiling, .x_gated = true },
        .{ .name = "clock_test", .gate = has_seg_clock, .x_gated = false },
        .{ .name = "systatus_test", .gate = has_seg_systatus, .x_gated = false },
        .{ .name = "carousel_test", .gate = has_seg_carousel, .x_gated = false },
        .{ .name = "brightness_test", .gate = has_seg_brightness, .x_gated = false },
        .{ .name = "commit_test", .gate = true, .x_gated = false },
        .{ .name = "slider_test", .gate = true, .x_gated = false },
        .{ .name = "native_alsa_test", .gate = true, .x_gated = false },
        .{ .name = "native_pulse_test", .gate = true, .x_gated = false },
        .{ .name = "model_test", .gate = has_minimize and has_fullscreen and has_floating and has_workspaces, .x_gated = false },
        .{ .name = "perf_test", .gate = has_minimize and has_fullscreen and has_workspaces, .x_gated = false },
        .{ .name = "schema_test", .gate = true, .x_gated = false },
        .{ .name = "tiling_test", .gate = has_tiling, .x_gated = false },
        .{ .name = "sync_test", .gate = has_tiling and has_minimize and has_fullscreen, .x_gated = false },
        .{ .name = "tracking_test", .gate = has_tiling and has_minimize and has_fullscreen, .x_gated = false },
        .{ .name = "workspaces_test", .gate = has_workspaces, .x_gated = false },
        .{ .name = "config_test", .gate = true, .x_gated = false },
        .{ .name = "parser_test", .gate = true, .x_gated = false },
        .{ .name = "persist_test", .gate = true, .x_gated = false },
        .{ .name = "visibility_test", .gate = has_bar, .x_gated = true },
        .{ .name = "wincache_test", .gate = true, .x_gated = false },
        .{ .name = "masks_test", .gate = true, .x_gated = false },
        .{ .name = "bounded_test", .gate = true, .x_gated = false },
        .{ .name = "idmap_test", .gate = true, .x_gated = false },
        .{ .name = "input_test", .gate = true, .x_gated = false },
        .{ .name = "keysyms_test", .gate = true, .x_gated = false },
        .{ .name = "borders_test", .gate = true, .x_gated = true },
        .{ .name = "borders_pure_test", .gate = true, .x_gated = false },
        .{ .name = "vim_test", .gate = has_vim and has_seg_prompt, .x_gated = false },
        .{ .name = "focus_latency_test", .gate = has_tiling, .x_gated = false },
        .{ .name = "tiling_latency_test", .gate = has_tiling, .x_gated = false },
    };
    {
        var test_it = discovery.modules.iterator();
        test_loop: while (test_it.next()) |entry| {
            if (!std.mem.endsWith(u8, entry.key_ptr.*, "_test")) continue;
            // Single table lookup: gate + x_gated together, so the
            // X-gated branching needs no separate name cascade. A discovered
            // *_test module missing from the table is a hard error: silently
            // running it ungated hides a feature dependency and can break the
            // deletion matrix (or let an X test race the shared display).
            const spec = for (test_gates) |g| {
                if (std.mem.eql(u8, entry.key_ptr.*, g.name)) break g;
            } else {
                std.debug.print(
                    "build: test module '{s}' has no test_gates entry; add it so its feature gate and X-serialization are explicit\n",
                    .{entry.key_ptr.*},
                );
                return error.UngatedTestModule;
            };
            if (!spec.gate) continue :test_loop;
            // Every test root links the same system libraries as the main
            // exe: the modules reached from a test graph may call X11/cairo
            // directly (window, drawing, ...) and no longer inherit linkage
            // second-hand from a blanket cross-wire.
            SystemLibraries.link(entry.value_ptr.*);
            const t = b.addTest(.{ .root_module = entry.value_ptr.* });
            const run = b.addRunArtifact(t);
            unit_test_step.dependOn(&run.step);
            if (spec.x_gated) {
                if (x_gated_run) |prev| run.step.dependOn(prev);
                x_gated_run = &run.step;
            }
        }
    }

    // Artifact & steps
    const exe = b.addExecutable(.{ .name = "hana", .root_module = root_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run hana").dependOn(&run_cmd.step);
    // Plugin-template compile gate: dev/plugin-template/** is compiled against
    // the real discovered modules (cross-wired like an in-tree module), so the
    // drop-in templates can't drift from current contracts without
    // `zig build check-plugin-template` (and by extension `zig build check`)
    // failing. Each template is only compiled when its imports are present.
    const plugin_template_specs = [_]PluginTemplateSpec{
        .{ .path = "dev/plugin-template/layout.zig", .import = "layout", .present = has_tiling },
        .{ .path = "dev/plugin-template/provider.zig", .import = "provider", .present = true },
        .{ .path = "dev/plugin-template/segment.zig", .import = "segment", .present = has_bar },
    };
    const plugin_template_check = try buildPluginTemplateCheck(b, &discovery.modules, shared_ctx, has_usr, target, optimize, &plugin_template_specs);
    // Layer guards: `zig build check` type-checks AND enforces the
    // sync-owned wire rules.
    const check_step = b.step("check", "Type-check + layer guards");
    check_step.dependOn(&exe.step);
    const layers = b.addSystemCommand(&.{"./dev/scripts/check-layers.sh"});
    layers.step.dependOn(&exe.step);
    check_step.dependOn(&layers.step);
    check_step.dependOn(plugin_template_check);

    // Deletion-modularity: each scenario copies the tree, removes an optional
    // subsystem, and builds it cold. That is far too heavy to fold into the
    // frequent `check` path, so it gets its own step (plus a `check-all`
    // aggregate) and is invoked from the pre-commit gate / CI instead.
    const check_modularity = b.step("check-modularity", "Build each feature-deletion scenario (see dev/scripts/check-modularity.sh)");
    check_modularity.dependOn(&b.addSystemCommand(&.{"./dev/scripts/check-modularity.sh"}).step);

    const check_all = b.step("check-all", "check + check-modularity");
    check_all.dependOn(check_step);
    check_all.dependOn(check_modularity);
}

// Shared context

/// Names claimed by `injectShared` that would collide with the generated
/// import every module receives. `plugins` is reserved for the chrome-surface
/// registration module; no `src/plugins.zig` may exist.
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

/// Generated source for the chrome-surface (bar) registration module. Kept
/// separate from per-owner `modules` registries so the bar's `Surfaces` seam
/// stays byte-identical.
const plugins_generated_source =
    \\const build_options = @import("build_options");
    \\
    \\/// The active chrome-surface hook set, or the comptime `null` type when no
    \\/// surface module is compiled in.
    \\pub const Surfaces = if (build_options.has_bar) @import("bar").surfaces else null;
;

/// A named import to wire into a generated module.
const Import = struct { name: []const u8, module: *std.Build.Module };

/// Creates a generated module from inline source, wiring the given imports.
///
/// The `.zig` suffix on `filename` matters: a compile-time arg
/// `-M<name>=<path>` with a root file lacking a recognized extension is
/// treated as a non-compilation unit and is never registered, so an import
/// of the generated module would fail to bind.
fn makeGeneratedModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    filename: []const u8,
    source: []const u8,
    imports: []const Import,
) *std.Build.Module {
    const write = b.addWriteFiles();
    const mod = b.createModule(.{
        .root_source_file = write.add(filename, source),
        .target = target,
        .optimize = optimize,
    });
    for (imports) |imp| mod.addImport(imp.name, imp.module);
    return mod;
}

/// Generates the build-owned `plugins` module alongside its source file, and
/// returns the module to inject everywhere via `injectShared`.
///
/// This is the single seam that concentrates core to chrome-surface coupling.
/// The source is written at build time via `addWriteFiles` and exposed as a
/// normal module (`b.createModule`), so nothing about it is committed. The
/// generated module is deliberately given only the imports its source
/// references (unlike discovered modules, which are cross-wired with
/// everything).
fn buildPluginsModule(
    b: *std.Build,
    discovered: *std.StringHashMap(*std.Build.Module),
    build_opts: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const mod = makeGeneratedModule(b, target, optimize, "plugins.zig", plugins_generated_source, &[_]Import{
        .{ .name = "build_options", .module = build_opts },
    });
    // The chrome-surface module is referenceable (`@import("bar")`) only when
    // its source was discovered; the comptime has_bar guard keeps the
    // no-registration case from ever being analyzed.
    if (discovered.get("bar")) |m| mod.addImport("bar", m);
    return mod;
}

/// Directory-scan discovery of `modules/` directories.
///
/// Each `modules/` dir is a set of pluggable sub-systems; the owner is the
/// parent directory. Stems are harvested during the single `src/` walk in
/// `DiscoveryContext.discoverAll` and sorted here for deterministic dispatch.
const OwnerRegistry = struct {
    /// Same as above, restricted to the stems that SELF-DECLARE the owner's
    /// module binding (`pub const module`), so a package core whose aggregate
    /// belt module is gone (systatus, slider) drops out of the owner registry
    /// and reaches `bar_modules` only through its derived `segmentFor(i)` entries.
    owners: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .{},

    /// owner name -> the `plugin.*` contract its modules bind (`window` ->
    /// WindowModule, `bar` -> Segment, `tiling` -> Layout). Derived from each
    /// owner's module files by `deriveOwnerContracts` (no hand table to
    /// drift from the modules' actual declarations).
    contracts: std.StringArrayHashMapUnmanaged([]const u8) = .{},

    /// Populates the registry from a pre-discovered `DiscoveryContext`. The
    /// context's `owner_stems` map was filled during the single `src/` walk
    /// (`discoverAll`); this method just converts it to sorted per-owner
    /// lists for deterministic dispatch order.
    fn run(discovery: *const Module.DiscoveryContext) !OwnerRegistry {
        var reg = OwnerRegistry{};
        var it = discovery.owner_stems.iterator();
        while (it.next()) |entry| {
            const dup_owner = try discovery.b.allocator.dupe(u8, entry.key_ptr.*);
            var list = std.ArrayListUnmanaged([]const u8).empty;
            for (entry.value_ptr.items) |stem| {
                // Only files SELF-DECLARING the owner's module binding
                // (`pub const module`) are registry members. A package core
                // WITHOUT one -- systatus/slider once their aggregate belt
                // module is gone -- contributes its readouts/controls to the
                // bar as standalone `segmentFor(i)` segments via
                // `ownerModuleEntries` instead (they stay discovered and
                // importable by stem; they just no longer ride one belt).
                const rel_path = discovery.source_paths.get(stem) orelse continue;
                if (try declaresBinding(discovery.b, rel_path, "module"))
                    try list.append(discovery.b.allocator, stem);
            }
            try reg.owners.put(discovery.b.allocator, dup_owner, list);
        }
        for (reg.owners.values()) |*list| {
            std.mem.sort([]const u8, list.items, {}, struct {
                fn lessThan(_: void, a: []const u8, b_: []const u8) bool {
                    return std.mem.lessThan(u8, a, b_);
                }
            }.lessThan);
        }
        return reg;
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
                    "<owner>_modules registry import every module gets. Rename or delete the file.\n",
                .{generated},
            );
            return error.ReservedModuleName;
        }
    }
    // Every package sub-addon registry (`<package>_subs`) and the tiling
    // seam are likewise injected into every module; a discovered file
    // claiming any of those names would shadow it. Reject loudly instead of
    // confusing later users of the name.
    for (sub_registry_specs) |spec| {
        const registry_name = try std.fmt.allocPrint(b.allocator, "{s}_subs", .{spec.package});
        if (discovered.contains(registry_name)) {
            std.debug.print(
                "Error: module name '{s}' collides with the build-generated " ++
                    "{s} sub-addon registry import. Rename or delete the file.\n",
                .{ registry_name, spec.package },
            );
            return error.ReservedModuleName;
        }
    }
    if (discovered.contains("tiling_seam")) {
        std.debug.print(
            "Error: module name 'tiling_seam' collides with the build-generated " ++
                "tiling seam import. Rename or delete the file.\n",
            .{},
        );
        return error.ReservedModuleName;
    }
}

/// The registry element type per owner is DERIVED from each owner's module
/// files instead of a hand-maintained table, so the generated
/// `<owner>_modules` typing cannot drift from the contracts the modules
/// actually bind to. Two declaration shapes are recognized, both yielding
/// the `plugin.*` contract the file binds its `module` value to:
///
///   1. `pub const module: @import("plugin").<Contract> = ...` — the typed
///      form used by the window/tiling sub-systems (floating, fullscreen,
///      minimize, workspaces, the tiling layouts) and by the explicitly
///      typed bar segments (prompt, systatus, tags, title, slider).
///   2. `pub const module = segdraw.module(...)` — the bar-core convenience
///      shim (clock, layout, variants); `segdraw.module` returns
///      `plugin.Segment` by construction, so the contract is the same name.
///   3. `pub const module = tiling.layoutModule(...)` — the tiling layouts;
///      `layoutModule` returns `plugin.Layout` by construction.
///
/// A brand-new `modules/` tree must declare one of these shapes or it is a
/// loud build error (the generated registry would otherwise mis-type every
/// module's `module` value). Across one owner, all modules must agree.
fn deriveOwnerContract(b: *std.Build, rel_path: []const u8) !?[]const u8 {
    const src = try b.build_root.handle.readFileAlloc(
        b.graph.io,
        rel_path,
        b.allocator,
        .limited(Module.max_scan_source_bytes),
    );
    defer b.allocator.free(src);

    const typed_needle = "pub const module: @import(\"plugin\").";
    const segdraw_needle = "pub const module = segdraw.module(";
    const layout_needle = "pub const module = tiling.layoutModule(";
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.indexOf(u8, trimmed, typed_needle)) |at| {
            const rest = trimmed[at + typed_needle.len ..];
            var n: usize = 0;
            while (n < rest.len) : (n += 1) {
                const c = rest[n];
                const is_name_char = (c >= 'a' and c <= 'z') or
                    (c >= 'A' and c <= 'Z') or
                    (c >= '0' and c <= '9');
                if (!is_name_char) break;
            }
            if (n == 0) return null;
            return try b.allocator.dupe(u8, rest[0..n]);
        }
        if (std.mem.indexOf(u8, trimmed, segdraw_needle) != null)
            return try b.allocator.dupe(u8, "Segment");
        if (std.mem.indexOf(u8, trimmed, layout_needle) != null)
            return try b.allocator.dupe(u8, "Layout");
    }
    return null;
}

const empty_owner_defaults = [_]struct { owner: []const u8, contract: []const u8 }{
    .{ .owner = "window", .contract = "WindowModule" },
    .{ .owner = "bar", .contract = "Segment" },
    .{ .owner = "tiling", .contract = "Layout" },
};

/// The empty-registry element type for an owner whose `modules/` tree holds
/// zero modules; see deriveOwnerContracts for why it can't be derived.
fn emptyOwnerDefaultContract(owner: []const u8) ?[]const u8 {
    for (empty_owner_defaults) |d| {
        if (std.mem.eql(u8, d.owner, owner)) return d.contract;
    }
    return null;
}

/// Fills `registry.contracts` (owner -> contract name) by scanning each
/// discovered module under the owner's `modules/` tree; every module must
/// agree on the contract, and at least one module must declare one. An owner
/// whose `modules/` tree holds ZERO modules binds a default: an empty registry
/// binds no module values, so its element type is consumer-binding metadata
/// (the typed `[]const plugin.X` a core tier casts the empty array to), not a
/// module-declared contract — nothing exists to derive it from, and only the
/// three known owners can ever appear empty (`window` when every behavior
/// module is removed).
fn deriveOwnerContracts(
    b: *std.Build,
    source_paths: *const std.StringHashMap([]const u8),
    registry: *OwnerRegistry,
) !void {
    var it = registry.owners.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.items.len == 0) {
            const fallback = emptyOwnerDefaultContract(entry.key_ptr.*) orelse {
                std.debug.print(
                    "Error: owner '{s}' has an empty modules/ tree and no declared empty-registry contract.\n",
                    .{entry.key_ptr.*},
                );
                return error.EmptyOwnerNoContract;
            };
            try registry.contracts.put(
                b.allocator,
                try b.allocator.dupe(u8, entry.key_ptr.*),
                try b.allocator.dupe(u8, fallback),
            );
            continue;
        }

        var contract: ?[]const u8 = null;
        var from: []const u8 = "";
        for (entry.value_ptr.items) |stem| {
            const rel_path = source_paths.get(stem) orelse continue;
            const c = (try deriveOwnerContract(b, rel_path)) orelse continue;
            if (contract) |known| {
                if (!std.mem.eql(u8, known, c)) {
                    std.debug.print(
                        "Error: owner '{s}' binds mixed contracts: '{s}' (via {s}) vs '{s}' (via {s}). All modules in a <owner>/modules/ tree must bind the same plugin contract.\n",
                        .{ entry.key_ptr.*, known, from, c, rel_path },
                    );
                    return error.MixedOwnerContract;
                }
            } else {
                contract = c;
                from = rel_path;
            }
        }
        if (contract) |c| {
            try registry.contracts.put(
                b.allocator,
                try b.allocator.dupe(u8, entry.key_ptr.*),
                try b.allocator.dupe(u8, c),
            );
        } else {
            std.debug.print(
                "Error: could not derive the module contract for owner '{s}': no 'pub const module' declaration found under its modules/ tree.\n",
                .{entry.key_ptr.*},
            );
            return error.CannotDeriveOwnerContract;
        }
    }
}

/// The sub-addon registries: each dir-named package under a `modules/` tree
/// whose private sibling files are addons of the package core binds them
/// through a generated `<package>_subs` module. `binding` is the decl each
/// sibling exposes, `array` the generated array name, `contract` the type
/// each sibling's value binds to (its parent package's open contract).
const sub_registry_specs = [_]struct {
    package: []const u8,
    array: []const u8,
    binding: []const u8,
    contract: []const u8,
    /// Packages whose bound subs are promoted to standalone BAR segments: one
    /// `@import("<package>").segmentFor(i)` entry per bound sub is appended to
    /// the generated `bar_modules` registry (see `ownerModuleEntries`), so each
    /// readout/control is individually selectable, orderable, and spaced in
    /// `[bar.layout.*]` rather than riding one aggregate "systatus"/"slider"
    /// belt. The package core exports `pub fn segmentFor(comptime i: usize)
    /// plugin.Segment`, and the entry index `i` always equals the sub's index
    /// in the generated `<package>_subs` registry (both consume the same
    /// sorted bound-sub list), so `segmentFor(i)` selects exactly `subs[i]`.
    bar_segments: bool = false,
}{
    .{ .package = "systatus", .array = "subs", .binding = "sub", .contract = "systatus.Sub", .bar_segments = true },
    .{ .package = "prompt", .array = "addons", .binding = "addon", .contract = "prompt.Addon" },
    .{ .package = "title", .array = "addons", .binding = "addon", .contract = "title.Scroller" },
    .{ .package = "slider", .array = "subs", .binding = "sub", .contract = "slider.Sub", .bar_segments = true },
};

/// True when `rel_path` declares the top-level binding `pub const <binding>`
/// -- the self-declaring role marker that turns a package sibling into a
/// bound addon. A sibling WITHOUT the declaration is a private implementation
/// file (native_alsa.zig beside the slider package): still registered as a
/// named module and importable by stem, but excluded from the generated
/// `<package>_subs` registry. Mirrors deriveOwnerContract's line-scan: the
/// declaration must be a real top-level decl of the binding name, not a
/// doc-comment reference.
fn declaresBinding(b: *std.Build, rel_path: []const u8, binding: []const u8) !bool {
    const src = try b.build_root.handle.readFileAlloc(
        b.graph.io,
        rel_path,
        b.allocator,
        .limited(Module.max_scan_source_bytes),
    );
    defer b.allocator.free(src);
    const needle = try std.fmt.allocPrint(b.allocator, "pub const {s}", .{binding});
    defer b.allocator.free(needle);
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "//")) continue;
        if (!std.mem.startsWith(u8, trimmed, needle)) continue;
        const rest = trimmed[needle.len..];
        if (rest.len == 0) continue;
        const next = rest[0];
        if (next == ':' or next == ' ' or next == '=') return true;
    }
    return false;
}

/// Filters one `sub_registry_spec`'s package siblings to those that
/// SELF-DECLARE the binding (`pub const <binding>`), sorts them
/// alphabetically, caches them (duped, sorted) in `out` keyed by the
/// package, and returns the map entry pointer (null when the package itself
/// isn't discovered -- its dir-named core file is absent, so nothing can
/// reference the generated registry).
///
/// The one sorted list feeds BOTH consumers, so their ordering can never
/// drift: the generated `<package>_subs` registry `subs[k]`, and the derived
/// bar segment `segmentFor(i)` with `i == k` (see `bar_segments` above). A
/// sibling without the binding (e.g. native_alsa.zig / native_pulse.zig
/// beside the slider package) stays a discovered, importable module but is
/// never bound.
fn boundSubStems(
    b: *std.Build,
    discovery: *const Module.DiscoveryContext,
    spec: anytype,
    out: *std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)),
) !?*std.ArrayListUnmanaged([]const u8) {
    if (!discovery.modules.contains(spec.package)) return null;
    var filtered = std.ArrayListUnmanaged([]const u8).empty;
    if (discovery.sub_stems.get(spec.package)) |stems| {
        for (stems.items) |stem| {
            const rel_path = discovery.source_paths.get(stem) orelse continue;
            if (try declaresBinding(b, rel_path, spec.binding))
                try filtered.append(b.allocator, stem);
        }
    }
    std.mem.sortUnstable([]const u8, filtered.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b_: []const u8) bool {
            return std.mem.lessThan(u8, a, b_);
        }
    }.lessThan);
    const dup = try b.allocator.dupe(u8, spec.package);
    try out.put(b.allocator, dup, filtered);
    return out.getPtr(dup).?;
}

/// One entry a generated `<owner>_modules` registry lists.
const OwnerEntry = struct {
    /// The import name the entry's expression resolves through, used to wire
    /// the module edge into the generated registry module
    /// (`@import("<owner>_modules")` adds this import to its own import table).
    import: []const u8,
    /// The full entry expression: `@import("<stem>").module` for a
    /// module-declaring stem, or `@import("<package>").segmentFor(<i>)` for a
    /// derived standalone bar segment.
    expr: []const u8,
};

/// Generates one synthesized `<owner>_modules` registry module per discovered
/// `modules/` dir and returns them keyed by their injectable import name.
/// Each registry source lists, in deterministic scan order, every discovered
/// sub-system module's `module` value, so core tiers iterate it with uniform
/// loops and never name a sub-system module. The bar registry additionally
/// appends -- AFTER the module-declaring stems, never intermixed -- one
/// `segmentFor(i)` entry per bound sub of each `bar_segments` package (see
/// `sub_registry_specs`): those packages no longer bind an aggregate belt
/// module, so their readouts/controls reach `bar_modules` only as these
/// derived entries. Committed source is behaviour-identical across presence
/// combinations; deleting a sub-system's file only regenerates a shorter
/// array.
fn buildOwnerRegistries(
    b: *std.Build,
    discovered: *std.StringHashMap(*std.Build.Module),
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    registry: *OwnerRegistry,
    bound_subs: *const std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)),
) !std.StringHashMapUnmanaged(*std.Build.Module) {
    var out = std.StringHashMapUnmanaged(*std.Build.Module){};
    var it = registry.owners.iterator();
    while (it.next()) |entry| {
        const name = try std.fmt.allocPrint(b.allocator, "{s}_modules", .{entry.key_ptr.*});
        const contract = registry.contracts.get(entry.key_ptr.*) orelse
            @panic("owner contract not derived; see deriveOwnerContracts");
        const entries = try ownerModuleEntries(
            b,
            std.mem.eql(u8, entry.key_ptr.*, "bar"),
            entry.value_ptr.*.items,
            bound_subs,
        );
        const mod = try buildOwnerRegistryModule(
            b,
            discovered,
            target,
            optimize,
            name,
            contract,
            entries.items,
        );
        try out.put(b.allocator, name, mod);
    }
    return out;
}

/// The entries one `<owner>_modules` registry lists. The standard member is
/// `@import("<stem>").module` per owner stem (module-declaring only, see
/// `OwnerRegistry.run`); a bar registry additionally appends one
/// `@import("<package>").segmentFor(k)` per bound sub of each `bar_segments`
/// package, iterated in `sub_registry_specs` order and, within a package, in
/// the same sorted order as its generated `<package>_subs` registry
/// (`k` == `subs[k]`; both consume `bound_subs`).
fn ownerModuleEntries(
    b: *std.Build,
    is_bar: bool,
    stems: []const []const u8,
    bound_subs: *const std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)),
) !std.ArrayListUnmanaged(OwnerEntry) {
    var entries = std.ArrayListUnmanaged(OwnerEntry).empty;
    for (stems) |stem| {
        try entries.append(b.allocator, .{
            .import = stem,
            .expr = try std.fmt.allocPrint(b.allocator, "@import(\"{s}\").module", .{stem}),
        });
    }
    if (is_bar) {
        for (sub_registry_specs) |spec| {
            if (!spec.bar_segments) continue;
            const subs = bound_subs.get(spec.package) orelse continue;
            for (subs.items, 0..) |_, k| {
                try entries.append(b.allocator, .{
                    .import = spec.package,
                    .expr = try std.fmt.allocPrint(b.allocator, "@import(\"{s}\").segmentFor({d})", .{ spec.package, k }),
                });
            }
        }
    }
    return entries;
}

/// Generates a single `<owner>_modules` registry module alongside its source
/// file. Imports are added only for what the source references: `plugin` (the
/// interface contract), every discovered sub-system stem it lists, and -- for
/// a bar registry -- each bar_segments package whose `segmentFor` entries it
/// lists. A stem that isn't discovered can't be listed (the scan walked the
/// real filesystem), so every listed import exists.
fn buildOwnerRegistryModule(
    b: *std.Build,
    discovered: *std.StringHashMap(*std.Build.Module),
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    contract: []const u8,
    entries: []const OwnerEntry,
) !*std.Build.Module {
    var src = std.ArrayList(u8).empty;
    try src.print(b.allocator, "const plugin = @import(\"plugin\");\n\n", .{});
    try src.print(b.allocator, "/// The auto-discovered `{s}` sub-system modules, in deterministic\n", .{name});
    try src.print(b.allocator, "/// filesystem scan order (dispatch order == this array's order).\n", .{});
    if (std.mem.eql(u8, name, "bar_modules")) {
        try src.appendSlice(b.allocator, "/// Bar registries additionally list derived standalone segments\n");
        try src.appendSlice(b.allocator, "/// (`segmentFor(i)`, see build.zig `bar_segments`) after the stems.\n");
    }
    try src.appendSlice(b.allocator, "/// Generated by build.zig; never committed.\n");
    try src.print(b.allocator, "pub const modules = [_]plugin.{s}{{\n", .{contract});
    for (entries) |e| {
        try src.print(b.allocator, "    {s},\n", .{e.expr});
    }
    try src.print(b.allocator, "}};\n", .{});

    const mod = makeGeneratedModule(b, target, optimize, b.fmt("{s}.zig", .{name}), src.items, &[_]Import{});

    if (discovered.get("plugin")) |m| mod.addImport("plugin", m);
    var added = std.StringHashMapUnmanaged(void){};
    defer added.deinit(b.allocator);
    for (entries) |e| {
        if (discovered.get(e.import)) |m| {
            if (added.contains(e.import)) continue;
            try added.put(b.allocator, e.import, {});
            mod.addImport(e.import, m);
        }
    }
    return mod;
}

/// Generates a `<package>_subs` registry module for a dir-named package's
/// private siblings (`systatus/{cpu,mem,...}.zig` beside systatus.zig,
/// `prompt/vim.zig` beside prompt.zig, `title/carousel.zig` beside
/// title.zig). Lists every discovered sibling that SELF-DECLARES the binding
/// (`pub const <binding>`) as the package's addon binding value (`sub`,
/// `addon`, ...) in the contract element `contract` (e.g. `prompt.Addon`),
/// in deterministic alphabetical stem order. A sibling without the binding is
/// a private implementation file and is left out of the registry entirely.
/// Consumed by the package core via `@import("<package>_subs")`, mirroring
/// `bar_modules` for the bar's segments: file presence fully drives
/// membership, so adding or removing a sibling regenerates the array with
/// zero source edits and leaves no dead references in the closed core. The
/// package core and its siblings may import each other; this generated module
/// is their only name-backed seam.
fn buildSubsRegistryModule(
    b: *std.Build,
    discovered: *std.StringHashMap(*std.Build.Module),
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    package: []const u8,
    array_name: []const u8,
    binding: []const u8,
    contract: []const u8,
    sub_stems: []const []const u8,
) !*std.Build.Module {
    const stems = try b.allocator.dupe([]const u8, sub_stems);
    std.mem.sortUnstable([]const u8, stems, {}, struct {
        fn lessThan(_: void, a: []const u8, b_: []const u8) bool {
            return std.mem.lessThan(u8, a, b_);
        }
    }.lessThan);

    var src = std.ArrayList(u8).empty;
    try src.print(b.allocator, "const {s} = @import(\"{s}\");\n\n", .{ package, package });
    try src.print(b.allocator, "/// The auto-discovered {s} sibling add-ons, in\n", .{package});
    try src.appendSlice(b.allocator, "/// deterministic alphabetical order. Generated by build.zig;\n");
    try src.print(b.allocator, "/// never committed. A sibling must export `pub const {s}: {s}` to be\n", .{ binding, contract });
    try src.appendSlice(b.allocator, "/// listed; a sibling without the binding is a private implementation\n");
    try src.appendSlice(b.allocator, "/// file and is left out of the registry. Membership is driven entirely\n");
    try src.appendSlice(b.allocator, "/// by file presence plus self-declared role.\n");
    try src.print(b.allocator, "pub const {s} = [_]{s}{{\n", .{ array_name, contract });
    for (stems) |stem| {
        try src.print(b.allocator, "    @import(\"{s}\").{s},\n", .{ stem, binding });
    }
    try src.appendSlice(b.allocator, "};\n");

    const registry_name = try std.fmt.allocPrint(b.allocator, "{s}_subs.zig", .{package});
    const mod = makeGeneratedModule(b, target, optimize, registry_name, src.items, &[_]Import{});
    if (discovered.get(package)) |m| mod.addImport(package, m);
    for (stems) |stem| {
        if (discovered.get(stem)) |m| mod.addImport(stem, m);
    }
    return mod;
}

/// Input to `buildPluginTemplateCheck`: one dev/plugin-template file to
/// compile against the real modules, the import name to expose it under in
/// the generated wrapper, and whether the current tree provides its
/// dependencies (a skipped entry is left out of the wrapper entirely).
const PluginTemplateSpec = struct {
    path: []const u8,
    import: []const u8,
    present: bool,
};

/// Compiles every `dev/plugin-template/` file against the REAL discovered
/// modules (cross-wired exactly like an in-tree module, shared artefacts
/// included) and registers a `check-plugin-template` step, so contract drift
/// self-fails on `zig build check`. Compile-only: the wrapper test binary is
/// built, never run. Importing each template and referencing its `module`
/// decl forces container analysis and contract-binding type-checking — an
/// import that no longer resolves, or a hook bound to a stale signature or
/// a deleted/renamed field (e.g. the pre-Round-3 opaque-cast `computeHook`,
/// `.has_variants`, `.coverageOn`), becomes a compile error here.
///
/// `specs` lists the template files with the import name the generated
/// wrapper exposes them under and whether the current tree provides their
/// dependencies (`present`); a skipped template is simply left out of the
/// wrapper source. Residual gap (by design): a template function body whose
/// called helper was renamed (rather than its signature/field changed) is
/// analyzed lazily, so it is flagged only once the tree's own modules use
/// the new name — the templates mirror those modules, which are themselves
/// compiled in-tree.
fn buildPluginTemplateCheck(
    b: *std.Build,
    discovered: *std.StringHashMap(*std.Build.Module),
    ctx: SharedBuildContext,
    has_usr: UsrDirs,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    specs: []const PluginTemplateSpec,
) !*std.Build.Step {
    var template_mods = std.StringHashMapUnmanaged(*std.Build.Module){};
    defer template_mods.deinit(b.allocator);

    for (specs) |spec| {
        if (!spec.present) continue;
        const mod = b.createModule(.{
            .root_source_file = b.path(spec.path),
            .target = target,
            .optimize = optimize,
        });
        mod.link_libc = true; // satisfy @cImport in imported core modules
        finalizeModule(mod, optimize, has_usr);
        injectShared(mod, ctx);
        var it = discovered.iterator();
        while (it.next()) |entry| {
            mod.addImport(entry.key_ptr.*, entry.value_ptr.*);
        }
        try template_mods.put(b.allocator, spec.import, mod);
    }

    // Generated wrapper: force container + registry-binding analysis of every
    // present template, then hand the module graph to an addTest built but not
    // executed (compiling a test is the established "type-check" primitive
    // here; `check` itself depends on the exe step the same way).
    var src = std.ArrayList(u8).empty;
    try src.appendSlice(b.allocator, "// Generated by build.zig; part of check-plugin-template.\n");
    try src.appendSlice(b.allocator, "comptime {\n");
    for (specs) |spec| {
        if (!spec.present) continue;
        try src.print(b.allocator, "    _ = @import(\"{s}\");\n", .{spec.import});
    }
    for (specs) |spec| {
        if (!spec.present) continue;
        try src.print(b.allocator, "    _ = @import(\"{s}\").module;\n", .{spec.import});
    }
    try src.appendSlice(b.allocator, "}\n");

    const wrapper = makeGeneratedModule(b, target, optimize, "plugin_templates.zig", src.items, &.{});
    wrapper.link_libc = true;
    finalizeModule(wrapper, optimize, has_usr);
    for (specs) |spec| {
        if (template_mods.get(spec.import)) |m| wrapper.addImport(spec.import, m);
    }

    const t = b.addTest(.{ .root_module = wrapper });
    const step = b.step("check-plugin-template", "Type-check dev/plugin-template/*.zig against current contracts");
    step.dependOn(&t.step);
    return step;
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

/// Memoized /usr directory existence (host-invariant within a build).
const UsrDirs = struct { lib: bool, include: bool };

fn finalizeModule(mod: *std.Build.Module, optimize: std.builtin.OptimizeMode, has_usr: UsrDirs) void {
    stripIfRelease(mod, optimize);
    if (has_usr.lib) mod.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    if (has_usr.include) mod.addIncludePath(.{ .cwd_relative = "/usr/include" });
}

// Module namespace discovery & wiring

/// Namespace that owns all logic related to module discovery and wiring.
///
/// Grouped here so the entry point (`build`) stays at a high level of abstraction.
const Module = struct {
    /// Maximum bytes read from a source file while scanning import edges or
    /// deriving owner contracts. A source file this large would be a different
    /// problem; the limit just keeps pathological inputs from pinning the
    /// build process.
    const max_scan_source_bytes = 4 * 1024 * 1024;

    /// Mutable state threaded through the entire discovery pass.
    ///
    /// Grouping it here means discoverAll and registerModule take only the arguments
    /// that actually vary per call, and future additions touch zero function signatures.
    const DiscoveryContext = struct {
        b: *std.Build,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        entry_point_path: []const u8,
        // None of the maps below is explicitly torn down: they and their
        // duped keys live in b.allocator, which is an arena scoped to the
        // whole build, so their lifetime already matches the process's.
        modules: std.StringHashMap(*std.Build.Module),
        source_paths: std.StringHashMap([]const u8),
        owner_stems: std.StringHashMap(std.ArrayListUnmanaged([]const u8)),
        /// Private siblings of dir-named packages under a `modules/` tree:
        /// `systatus/cpu.zig` next to `systatus/systatus.zig` is recorded as
        /// "systatus" -> ["cpu", ...]. Consumed by the generated
        /// `<package>_subs` registries (systatus_subs, prompt_subs,
        /// title_subs), mirroring owner_stems.
        sub_stems: std.StringHashMap(std.ArrayListUnmanaged([]const u8)),

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
                .owner_stems = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(b.allocator),
                .sub_stems = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(b.allocator),
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
            try ctx.discoverAll(dir_path, null, false);
            return ctx;
        }

        /// Recursively walks `dir_path` and registers every `.zig` file as a
        /// named module, except the entry point itself (`ctx.entry_point_path`).
        ///
        /// `owner`/`in_modules_root` carry the owner-stem context so the
        /// `modules/` dirs are captured during this SAME walk (no second
        /// iteration): once the walk is inside a `<owner>/modules/` tree,
        /// every `.zig` file is a registry-stem candidate — directly in the
        /// modules dir all files count, in a deeper subdirectory only the one
        /// sharing its directory's name (see addOwnerStem). `owner` is a
        /// b.allocator-backed slice (a basename into an ancestor `dir_path`
        /// dupe), valid for the whole build.
        fn discoverAll(ctx: *DiscoveryContext, dir_path: []const u8, owner: ?[]const u8, in_modules_root: bool) !void {
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

                        if (std.mem.eql(u8, entry.name, "modules")) {
                            const modules_owner = std.fs.path.basename(dir_path);
                            if (modules_owner.len != 0) {
                                try ctx.ensureOwnerStems(modules_owner);
                                try ctx.discoverAll(try b.allocator.dupe(u8, subdir_path), modules_owner, true);
                                continue;
                            }
                        }

                        try ctx.discoverAll(
                            try b.allocator.dupe(u8, subdir_path),
                            owner,
                            false,
                        );
                    },

                    .file => {
                        if (!isZigSource(entry.name)) continue;

                        const rel_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name });
                        if (std.mem.eql(u8, rel_path, ctx.entry_point_path)) continue;

                        try ctx.registerModule(try b.allocator.dupe(u8, rel_path));

                        if (owner) |o| {
                            if (in_modules_root or std.mem.eql(u8, std.fs.path.stem(entry.name), std.fs.path.basename(dir_path))) {
                                try ctx.addOwnerStem(o, std.fs.path.stem(entry.name));
                            } else {
                                // A private sibling of a dir-named package
                                // (systatus/{cpu,mem,...}.zig beside
                                // systatus.zig): parked under the package stem
                                // for its generated `<package>_subs` registry
                                // rather than becoming an owner stem.
                                try ctx.addSubStem(std.fs.path.basename(dir_path), std.fs.path.stem(entry.name));
                            }
                        }
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

        /// Prepares `owner`'s stem list (deduped, unsorted; `OwnerRegistry.run`
        /// sorts for deterministic dispatch order). Called the first time the
        /// walk enters a `<owner>/modules/` tree.
        fn ensureOwnerStems(ctx: *DiscoveryContext, owner: []const u8) !void {
            const b = ctx.b;
            const gop = try ctx.owner_stems.getOrPut(try b.allocator.dupe(u8, owner));
            if (!gop.found_existing) gop.value_ptr.* = .empty;
        }

        /// Appends `stem` to `owner`'s list unless already present. Called
        /// from `discoverAll`'s file case (the single walk), never from a
        /// second directory iteration.
        fn addOwnerStem(ctx: *DiscoveryContext, owner: []const u8, stem: []const u8) !void {
            const gop = ctx.owner_stems.getPtr(owner) orelse return;
            for (gop.items) |existing| {
                if (std.mem.eql(u8, existing, stem)) return;
            }
            const dup_stem = try ctx.b.allocator.dupe(u8, stem);
            try gop.append(ctx.b.allocator, dup_stem);
        }

        /// Appends `stem` as a private sibling of the dir-named package
        /// `package` (systatus/cpu.zig inside the systatus package). Deduped,
        /// unsorted; `buildSubsRegistryModule` sorts for deterministic output.
        fn addSubStem(ctx: *DiscoveryContext, package: []const u8, stem: []const u8) !void {
            const gop = try ctx.sub_stems.getOrPut(try ctx.b.allocator.dupe(u8, package));
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            for (gop.value_ptr.items) |existing| {
                if (std.mem.eql(u8, existing, stem)) return;
            }
            const dup_stem = try ctx.b.allocator.dupe(u8, stem);
            try gop.value_ptr.append(ctx.b.allocator, dup_stem);
        }
    };

    /// Scans a module's source for `@import("name")` literals and appends
    /// every name that corresponds to a discovered module to `out` (each name
    /// is dupe'd for the caller, which must free it). Imports that are NOT
    /// discovered modules — `std`, `builtin`, and the shared-injected names
    /// from `injectShared` (build_options, fallback_toml, plugins,
    /// `<owner>_modules`) — are skipped: they either need no wiring or are
    /// already present in the module's import_table.
    ///
    /// Precise edges are what rescue the compile CACHE from the old blanket
    /// cross-wire. With every module importing every module, any one file's
    /// churn invalidated every module's cached compilation — O(n²) in module
    /// count, paid on every incremental rebuild even though the compiler
    /// elides unused imports at analysis time. Wiring only the edges a module
    /// actually declares makes cache invalidation follow real dependencies.
    fn importEdgesOf(
        b: *std.Build,
        rel_path: []const u8,
        modules: *std.StringHashMap(*std.Build.Module),
        out: *std.ArrayListUnmanaged([]const u8),
    ) !void {
        const src = try b.build_root.handle.readFileAlloc(
            b.graph.io,
            rel_path,
            b.allocator,
            .limited(Module.max_scan_source_bytes),
        );
        defer b.allocator.free(src);

        const needle = "@import(\"";
        var i: usize = 0;
        while (i + needle.len <= src.len) {
            if (!std.mem.startsWith(u8, src[i..], needle)) {
                i += 1;
                continue;
            }
            i += needle.len;
            const name_start = i;
            while (i < src.len and src[i] != '"') : (i += 1) {}
            if (i >= src.len) break;
            const name = src[name_start..i];
            if (!std.mem.eql(u8, name, "std") and
                !std.mem.eql(u8, name, "builtin") and
                modules.contains(name))
            {
                try out.append(b.allocator, try b.allocator.dupe(u8, name));
            }
            i += 1; // move past the closing quote
        }
    }

    /// Layer-purity assertion for the pure layers (model, tiling, config),
    /// enforced on the SAME import edges wireAll already derives for
    /// cross-wiring — one graph, so it cannot drift from a second hand-kept
    /// dependency list. The hub layers (core, window, input, bar) may import
    /// each other at will (hub-and-spoke); the pure layers may only depend on
    /// the shared utility shelf and their own neighborhood. Because any
    /// import cycle with a pure member needs the pure module to reach INTO
    /// the hub, this makes pure-layer cycles structurally impossible and
    /// catches regressions like the old config -> xkbcommon -> core -> config
    /// cycle (config now parses keysym names through the pure `keysyms`).
    ///
    /// This check is the IMPORT-EDGE guard only. The complementary body/
    /// reference sweep (any bare `xcb` token in model/ and tiling/, comments
    /// stripped) lives in check-layers.sh Rule 3 — an import of an xcb-using
    /// module passes here yet still lets `xcb` reach a pure file by
    /// re-export, so Rule 3 -- not this function -- is the sole guard on
    /// pure-layer xcb BODIES.
    fn assertPureLayerImports(
        name: []const u8,
        rel_path: []const u8,
        edges: []const []const u8,
    ) !void {
        const layer = if (std.mem.startsWith(u8, rel_path, "src/model/"))
            "model"
        else if (std.mem.startsWith(u8, rel_path, "src/tiling/"))
            "tiling"
        else if (std.mem.startsWith(u8, rel_path, "src/config/"))
            "config"
        else
            return;

        for (edges) |dep| {
            if (!pureLayerAllows(layer, dep)) {
                std.debug.print(
                    "Error: layer guard: pure-{s} module '{s}' imports hub module '{s}'. The pure layers may only import the shared utility shelf, `model`, and their own layer; see assertPureLayerImports in build.zig.\n",
                    .{ layer, name, dep },
                );
                return error.LayerGuardViolation;
            }
        }
    }

    /// The allowed-import policy behind `assertPureLayerImports`. The shared
    /// utility shelf is xcb-free by construction and safe for every layer;
    /// `model` is the shared data model; the per-layer extras are the pure
    /// neighborhoods each layer legitimately reaches (tiling's own seam plus
    /// the `plugin` contract decls; config's own parsing siblings plus the
    /// pure `keysyms`). Anything else is hub wiring and belongs behind an
    /// interface, not an import.
    fn pureLayerAllows(layer: []const u8, dep: []const u8) bool {
        const shelf = [_][]const u8{
            "constants", "debug", "ids", "masks", "utils", "paths", "proc", "bounded", "idmap",
        };
        for (shelf) |m| if (std.mem.eql(u8, m, dep)) return true;
        if (std.mem.eql(u8, dep, "model")) return true;
        if (std.mem.eql(u8, layer, "model")) return false;
        if (std.mem.eql(u8, layer, "tiling")) {
            return std.mem.eql(u8, dep, "tiling") or std.mem.eql(u8, dep, "plugin");
        }
        if (std.mem.eql(u8, layer, "config")) {
            const siblings = [_][]const u8{ "parser", "schema", "types", "fallback", "keysyms" };
            for (siblings) |m| if (std.mem.eql(u8, m, dep)) return true;
        }
        return false;
    }

    /// Wires up all discovered modules together.
    ///
    /// Injects shared imports into `root` itself, then into every discovered
    /// module, before cross-wiring each discovered module with every other
    /// module it actually `@import`s, then exposing them all to `root`. This
    /// gives every module access to every other module by name without
    /// hand-maintained dependency lists.
    ///
    /// The wiring follows REAL dependency edges (see `importEdgesOf`) rather
    /// than a blanket every-module-imports-every-module cross-wire. The two
    /// approaches are functionally identical — a module can only use symbols
    /// it imports with an `@import`, and unused blanket edges are elided at
    /// analysis time — but they diverge on the compile CACHE: blanket wiring
    /// keyed every module on every other module's hash, so a change to *any*
    /// file invalidated every module's cached compilation (O(n²) in module
    /// count, paid on every incremental rebuild). Edge-based wiring keeps
    /// invalidation proportional to real dependencies.
    fn wireAll(
        b: *std.Build,
        root: *std.Build.Module,
        all: *std.StringHashMap(*std.Build.Module),
        source_paths: *std.StringHashMap([]const u8),
        ctx: SharedBuildContext,
    ) !void {
        // Wiring follows declared `@import` edges. Layer purity for the pure
        // layers (model/tiling/config) is enforced HERE, at build time, on
        // those same edges (`assertPureLayerImports`, below): a pure module
        // importing hub wiring fails the build instead of merely being caught
        // later by dev/scripts/check-layers.sh at `zig build check`. That
        // makes pure-layer import cycles structurally impossible and keeps
        // config off the X-wired input stack.
        injectShared(root, ctx);

        var outer = all.iterator();
        while (outer.next()) |entry| {
            const mod = entry.value_ptr.*;
            const name = entry.key_ptr.*;

            injectShared(mod, ctx);

            // Precise cross-wiring: an import edge is added only for every
            // discovered module the source actually `@import`s. Edges the scan
            // can't see (generated registries, shared-injected names) are
            // already in the import_table via injectShared. Read failures are
            // logged and skipped — the module's own compile would fail anyway,
            // and a missing edge surfaces a clear "no module named" error.
            var edges = std.ArrayListUnmanaged([]const u8).empty;
            defer edges.deinit(b.allocator);
            if (source_paths.get(name)) |rel_path| {
                importEdgesOf(b, rel_path, all, &edges) catch |err| {
                    std.debug.print(
                        "Error: could not scan {s} for import edges: {s}\n",
                        .{ rel_path, @errorName(err) },
                    );
                };
                try assertPureLayerImports(name, rel_path, edges.items);
            }
            for (edges.items) |dep_name| {
                if (mod.import_table.contains(dep_name)) continue;
                if (all.get(dep_name)) |dep_mod| mod.addImport(dep_name, dep_mod);
                b.allocator.free(dep_name);
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
};

// System library linkage

/// Namespace that owns all system library linkage.
///
/// Helps keep `build()` clean.
const SystemLibraries = struct {
    /// System libraries hana links against, by name. The single source of
    /// truth is build.zig.zon's own `.links` table: `loadLinks` reads it at
    /// build time (every `zig build` re-reads the file), so this set can
    /// never drift from the package-side declaration. A consumer depending on
    /// hana as a package gets the same set applied on its own build by the
    /// package mechanism (idempotent with these calls).
    var links: []const []const u8 = &.{};

    /// The parcel of build.zig.zon this build cares about. Field-for-field
    /// shape of the manifest so the parser walks the whole file (zon rejects
    /// unknown fields), with the name enum spelled out because `.{ .name = .hana }`
    /// deserializes only into a matching enum literal type.
    const Name = enum { hana };
    const Zon = struct {
        name: Name,
        fingerprint: u64,
        version: []const u8,
        minimum_zig_version: []const u8,
        paths: []const []const u8,
        links: []const []const u8,
    };

    /// Populates `links` from build.zig.zon. An unreadable or unparsable
    /// `.links` fails the build (an empty set would silently link nothing,
    /// which a runtime relocation error would surface much later).
    fn loadLinks(b: *std.Build) !void {
        const src = try b.build_root.handle.readFileAlloc(
            b.graph.io,
            "build.zig.zon",
            b.allocator,
            .limited(1 << 16),
        );
        var diag: std.zon.parse.Diagnostics = .{};
        defer diag.deinit(b.allocator);
        const parsed = std.zon.parse.fromSliceAlloc(
            Zon,
            b.allocator,
            try b.allocator.dupeZ(u8, src),
            &diag,
            .{},
        ) catch |err| {
            std.debug.print("SystemLibraries: build.zig.zon `.links` unparsable:\n", .{});
            var it = diag.iterateErrors();
            while (it.next()) |d| std.debug.print("  {}\n", .{d});
            return err;
        };
        if (parsed.links.len == 0) return error.EmptyLinksDeclaration;
        links = parsed.links;
    }

    /// Links the system libraries declared in build.zig.zon.
    fn link(root: *std.Build.Module) void {
        for (links) |lib| root.linkSystemLibrary(lib, .{});
    }
};
