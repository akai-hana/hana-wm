//! hana's build configuration
//! Includes module auto-discovery: every .zig file under src/ becomes a
//! named module, available to import from every other module.
//!
//! This script uses newer standard-library APIs (e.g. the Io-based
//! filesystem calls below), so it needs a recent Zig. The minimum supported
//! compiler is declared in build.zig.zon's `minimum_zig_version` field rather
//! than guarded here: that is the field version managers and editors (zvm,
//! mise, vscode-zig) read.

const std = @import("std");

/// Shared comparator for the four sorted module/stem name lists in this file,
/// so their sort bodies cannot drift apart.
fn lessStrings(_: void, a: []const u8, b_: []const u8) bool {
    return std.mem.lessThan(u8, a, b_);
}

// Configuration
//
// Every path (and path-adjacent limit) this build script depends on,
// gathered in one place so they're easy to audit together instead of being
// scattered as inline literals.

// No trailing slash: discoverAll joins paths as "{dir}/{name}", so a trailing
// slash would yield "src//..." rel_paths and miss the layer guard's
// "src/config/" prefix tests.
const source_root = "src";
const entry_point_path = source_root ++ "/main.zig";
const fallback_toml_path = "config/fallback.toml";
// Cap on the fallback-config read; it is configuration, not data.
const max_fallback_toml_bytes = 1024 * 1024;

// Entry point

/// hana's default build is ReleaseFast, not Debug.
///
/// Resolved here rather than through `standardOptimizeOption`: that helper
/// only applies `preferred_optimize_mode` when the build is *already* in a
/// release mode, so with it a bare `zig build` yields Debug and
/// `-Doptimize` is not even registered. Debug is a bad default here in any
/// case: it keeps every `std.log.debug` call in the binary and measures far
/// slower startup work, so the default belongs in this script.
///
/// Precedence, highest first:
///   -Doptimize=<Debug|ReleaseSafe|ReleaseFast|ReleaseSmall>
///   --release=<fast|safe|small>          (or the legacy `-Drelease`)
///   ReleaseFast                          (the default)
fn resolveOptimize(b: *std.Build) std.builtin.OptimizeMode {
    if (b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size (default: ReleaseFast)",
    )) |mode| return mode;

    // Aliased so `-Drelease` keeps working; it means `--release=fast`.
    const legacy_release = b.option(bool, "release", "Optimize for end users (same as --release=fast)") orelse false;
    if (legacy_release) return .ReleaseFast;

    return switch (b.release_mode) {
        // `.off` is the bare `zig build` case, and `.any` is a bare
        // `--release`; both mean "whatever release mode hana prefers".
        .off, .any, .fast => .ReleaseFast,
        .safe => .ReleaseSafe,
        .small => .ReleaseSmall,
    };
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .native } });
    const optimize = resolveOptimize(b);

    if (target.result.os.tag != .linux) {
        std.debug.print(
            "Fatal: hana only supports Linux (it links against xcb, xkbcommon-x11, and pango/cairo).\n",
            .{},
        );
        return error.UnsupportedTarget;
    }

    // Embed config/fallback.toml at build time; an absent file becomes an
    // empty stub rather than a failed build. Read AFTER discovery (moved from
    // the top of build) so the line-level filter can drop the `[tiling...]` /
    // `[bar...]` / `[workspaces]` / `[drag]` blocks of subsystems absent from
    // this tree -- the fallback is shared source for every modularity shape.
    // Build options
    const build_opts = b.addOptions();
    build_opts.addOption(bool, "profile_key", b.option(bool, "profile-key", "Instrument the key dispatch path to log receive->action latency") orelse false);
    // Latency/benchmark tests record their timings to `.zig-cache/bench/
    // timings.txt` and run their full loops only when `-Dbench` is passed;
    // the default suite keeps them as cheap smoke runs so a passing
    // `zig build test` never writes to stderr (the build runner flags any
    // test stderr as `failed command:` even on success).
    const bench_enabled = b.option(bool, "bench", "Run latency/benchmark tests with full iteration counts and timing output (opt-in; off by default)") orelse false;
    build_opts.addOption(bool, "bench", bench_enabled);

    // Module discovery — runs before has_* probes so file-existence flags can
    // be derived from the discovered module set instead of re-probing the
    // filesystem.
    var discovery = try Module.DiscoveryContext.run(b, target, optimize, source_root, entry_point_path);

    const features = probeFeatures(&discovery, build_opts);

    // Config fragments (`*_config` stems) drive the generated `composed`
    // facade; discovered here so an orphan fragment fails the build before
    // any generated source references it.
    const config_fragments = try discoverConfigFragments(b, &discovery);

    const fallback_toml = filterFallbackToml(b, readFallbackToml(b), &discovery);
    const fallback_toml_mod = buildFallbackTomlModule(b, fallback_toml, target, optimize);

    // Restrict the run to one *_test stem. Applied in wireUnitTests, where a
    // name matching nothing is a hard error rather than a silent empty run.
    const test_filter = b.option([]const u8, "test-filter", "Run only this *_test file (e.g. model_test)");

    // `zig build modules`: the discovered stem table, answerable without
    // reading discovery code. The walk already ran, so the output is baked
    // into a printf command at configure time — no custom step machinery.
    {
        var keys: std.ArrayList([]const u8) = .empty;
        defer keys.deinit(b.allocator);
        var mit = discovery.modules.keyIterator();
        while (mit.next()) |k| try keys.append(b.allocator, k.*);
        std.mem.sort([]const u8, keys.items, {}, lessStrings);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(b.allocator);
        for (keys.items) |k| try buf.print(b.allocator, "{s}\n", .{k});
        const modules_step = b.step("modules", "Print the discovered module stem table (sorted)");
        modules_step.dependOn(&b.addSystemCommand(&.{ "printf", "%s", buf.items }).step);
    }

    const gen = try buildGeneratedModules(b, &discovery, config_fragments, build_opts, target, optimize);
    const build_opts_mod = gen.build_opts_mod;
    const surfaces_mod = gen.surfaces_mod;
    const has_usr = gen.has_usr;
    const owner_modules = gen.owner_modules;

    const shared_ctx: SharedBuildContext = .{
        .build_opts = build_opts_mod,
        .fallback_toml = fallback_toml_mod,
        .surfaces = surfaces_mod,
        .owner_modules = owner_modules,
    };

    const root_mod = try wireRootModule(b, target, optimize, has_usr, shared_ctx, &discovery);
    const unit_test_step = try wireUnitTests(b, &discovery, features, test_filter);
    const exe_step = buildExeAndRunStep(b, root_mod);
    wireBenchStep(b, bench_enabled, unit_test_step);
    try wireCheckSteps(b, exe_step, &discovery, features, shared_ctx, has_usr, target, optimize);
}

// Shared context

/// Names claimed by `injectShared` that would collide with the generated
/// import every module receives. `surfaces` is reserved for the chrome-surface
/// registration module; no `src/surfaces.zig` may exist. `composed` is the
/// build-generated config facade (see `buildComposedModule`); no
/// `src/composed.zig` may exist.
const reserved_module_names = [_][]const u8{ "build_options", "fallback_toml", "surfaces", "composed" };

/// Shared artefacts injected into every module, root and discovered alike.
const SharedBuildContext = struct {
    build_opts: *std.Build.Module,
    fallback_toml: *std.Build.Module,
    /// The build-generated chrome-surface registration module created by
    /// `buildSurfacesModule` (exports `Surfaces`). Injected into every module
    /// so core source can `@import("surfaces").Surfaces` without ever naming
    /// the bar. A hook set rather than a registry of discovered modules, so it
    /// is kept apart from the per-owner `modules` registries.
    surfaces: *std.Build.Module,
    /// The build-generated per-owner `modules` registries created by
    /// `buildOwnerRegistries`, keyed by their injectable import name
    /// (`<owner>_modules`, e.g. `window_modules`). Injected into every module
    /// so core source can `@import("window_modules").modules` to iterate an
    /// owner's auto-discovered sub-system set with uniform loops.
    owner_modules: std.StringHashMapUnmanaged(*std.Build.Module),
};

// Helpers

/// Every feature/segment presence flag derived from the discovered module
/// set, in one value. The has_* flags are published as build options inside
/// `probeFeatures`; the seg/level/volume flags stay private to this file
/// (test gate table and plugin-template specs).
const FeatureSet = struct {
    has_tiling: bool,
    has_floating: bool,
    has_minimize: bool,
    has_fullscreen: bool,
    has_workspaces: bool,
    has_bar: bool,
    has_vim: bool,
    has_seg_clock: bool,
    has_seg_carousel: bool,
    has_seg_prompt: bool,
    has_seg_systatus: bool,
    has_seg_brightness: bool,
    has_seg_slider: bool,
    has_seg_title: bool,
    has_level: bool,
    has_volume: bool,

    /// Feature name -> is-it-built bool, for `readTestGate`. A gate a test
    /// declares in its own source resolves through this; naming a feature
    /// that does not exist is a hard error in the reader, not a silent skip.
    fn featureFlags(self: FeatureSet) [16]FeatureFlag {
        return [_]FeatureFlag{
            .{ .name = "tiling", .on = self.has_tiling },
            .{ .name = "floating", .on = self.has_floating },
            .{ .name = "minimize", .on = self.has_minimize },
            .{ .name = "fullscreen", .on = self.has_fullscreen },
            .{ .name = "workspaces", .on = self.has_workspaces },
            .{ .name = "bar", .on = self.has_bar },
            .{ .name = "vim", .on = self.has_vim },
            .{ .name = "seg_clock", .on = self.has_seg_clock },
            .{ .name = "seg_carousel", .on = self.has_seg_carousel },
            .{ .name = "seg_prompt", .on = self.has_seg_prompt },
            .{ .name = "seg_systatus", .on = self.has_seg_systatus },
            .{ .name = "seg_brightness", .on = self.has_seg_brightness },
            .{ .name = "seg_slider", .on = self.has_seg_slider },
            .{ .name = "seg_title", .on = self.has_seg_title },
            .{ .name = "level", .on = self.has_level },
            .{ .name = "volume", .on = self.has_volume },
        };
    }
};

/// Optional-module detection: every has_* flag is derived from
/// discovery.modules (the single src/ walk) rather than re-probing the
/// filesystem, so a flag can never disagree with what was actually
/// discovered. Returns the full set; the has_* build options are published
/// inside.
fn probeFeatures(discovery: *const Module.DiscoveryContext, build_opts: *std.Build.Step.Options) FeatureSet {
    // Derived from the walk, not a fresh stat: a directory left behind after
    // its module files were removed no longer claims the flag.
    const has_tiling = discovery.modules.contains("tiling");
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

    // The bar exists only if all four internals are discovered; missing any
    // one forfeits the whole bar.
    const has_drawing = discovery.modules.contains("drawing");
    const has_bar_win = discovery.modules.contains("win");
    const has_bar_segment = discovery.modules.contains("segment");
    const has_bar_orchestrator = discovery.modules.contains("bar");
    const has_bar = has_bar_orchestrator and has_drawing and has_bar_win and has_bar_segment;
    build_opts.addOption(bool, "has_bar", has_bar);

    // Consumed only by the test gate table and the plugin-template specs
    // below, so these are never published as build options.
    const has_seg_clock = discovery.modules.contains("clock");
    const has_seg_carousel = discovery.modules.contains("carousel");
    const has_seg_prompt = discovery.modules.contains("prompt");
    const has_seg_systatus = discovery.modules.contains("systatus");
    const has_seg_brightness = discovery.modules.contains("brightness");
    const has_seg_slider = discovery.modules.contains("slider");
    const has_seg_title = discovery.modules.contains("title");
    // Level and volume are module-published too: tests vary which segment is
    // present, so their presence cannot be inferred from a seg_* flag.
    const has_level = discovery.modules.contains("level");
    const has_volume = discovery.modules.contains("volume");

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
    return .{
        .has_tiling = has_tiling,
        .has_floating = has_floating,
        .has_minimize = has_minimize,
        .has_fullscreen = has_fullscreen,
        .has_workspaces = has_workspaces,
        .has_bar = has_bar,
        .has_vim = has_vim,
        .has_seg_clock = has_seg_clock,
        .has_seg_carousel = has_seg_carousel,
        .has_seg_prompt = has_seg_prompt,
        .has_seg_systatus = has_seg_systatus,
        .has_seg_brightness = has_seg_brightness,
        .has_seg_slider = has_seg_slider,
        .has_seg_title = has_seg_title,
        .has_level = has_level,
        .has_volume = has_volume,
    };
}

/// Generated registration modules: the /usr probe memo, the chrome-surface
/// module, the per-owner registries (plus their package sub-addon registries)
/// and the tiling seam, all finalized with the shared system paths.
const GeneratedModules = struct {
    build_opts_mod: *std.Build.Module,
    surfaces_mod: *std.Build.Module,
    owner_modules: std.StringHashMapUnmanaged(*std.Build.Module),
    has_usr: UsrDirs,
};

fn buildGeneratedModules(
    b: *std.Build,
    discovery: *Module.DiscoveryContext,
    config_fragments: []const ConfigFragment,
    build_opts: *std.Build.Step.Options,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !GeneratedModules {
    // Generated registration modules. Built after discovery (the contract-bound
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
    // `surfaces` carries only the chrome-surface (bar) hook contract; window
    // behaviors arrive through the per-owner `modules` registries below.
    const surfaces_mod = buildSurfacesModule(b, &discovery.modules, build_opts_mod, target, optimize);
    finalizeModule(surfaces_mod, optimize, has_usr);

    // Owner-registry discovery: `modules/` dirs found during the single src/
    // walk above populate per-owner stem lists, which are sorted here for
    // deterministic dispatch order. This runs before `buildOwnerRegistries`,
    // which consumes those lists.
    var registry = try OwnerRegistry.run(discovery);
    // Sub-addon registries, derived from what the tree imports (see
    // `discoverSubRegistrySpecs`): discovered here so the reserved-name check
    // below sees the `<package>_subs` names they will claim.
    const sub_specs = try discoverSubRegistrySpecs(b, discovery);
    try validateRegistryNames(b, &registry, &discovery.modules, sub_specs);
    // Contract names are read from the modules' own `pub const module`
    // declarations (typed or via the segment builder), never from a hand-written table.
    // The classification is single-read memoized during discovery, so this
    // pass adds no source re-reads.
    try deriveOwnerContracts(b, discovery, &registry);
    // Precompute each package's bound-sub list (siblings self-declaring the
    // binding, sorted alphabetically) BEFORE either consumer needs it: every
    // generated `<package>_subs` registry is one such list, and the
    // `segmentFor(i)` entries a `bar_segments` package contributes to
    // `bar_modules` index the SAME sorted list (`i` == `subs[i]`), so the two
    // orderings can never drift from each other.
    var bound_subs = std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)){};
    for (sub_specs) |spec| {
        _ = try boundSubStems(b, discovery, spec, &bound_subs);
    }
    var owner_modules = try buildOwnerRegistries(b, &discovery.modules, target, optimize, &registry, &bound_subs, sub_specs);
    // Package sub-addon registries (`<package>_subs`), generated from file
    // presence the same way the owner registries are, so a package core
    // (systatus, prompt, title, ...) never names one of its addon siblings
    // (readouts, the vim engine, the carousel). Dropping a sibling file only
    // regenerates a shorter array; nothing in the closed core is touched.
    // Injected through `owner_modules` so every module sees the generated
    // import like the other registries.
    for (sub_specs) |spec| {
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
    // Tiling-engine seam: core and input import this generated module instead
    // of naming src/tiling/, so deleting the tiling subsystem leaves no
    // dangling import. See buildTilingSeamModule for the absent case.
    try owner_modules.put(
        b.allocator,
        "tiling_seam",
        buildTilingSeamModule(b, &discovery.modules, build_opts_mod, target, optimize),
    );
    // Config facade: the composed top-level Config assembled from the
    // discovered `*_config` fragments. Injected into every module through
    // owner_modules (like the registries) so config.zig, main, and the tests
    // all reach it as `@import("composed")`.
    try owner_modules.put(
        b.allocator,
        "composed",
        buildComposedModule(b, &discovery.modules, config_fragments, build_opts_mod, target, optimize),
    );
    var oms_it = owner_modules.valueIterator();
    while (oms_it.next()) |m| {
        finalizeModule(m.*, optimize, has_usr);
    }
    return .{ .build_opts_mod = build_opts_mod, .surfaces_mod = surfaces_mod, .owner_modules = owner_modules, .has_usr = has_usr };
}

/// Root module: created, finalized with the shared system paths, cross-wired
/// with every discovered module, and linked against the system libraries.
fn wireRootModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    has_usr: UsrDirs,
    shared_ctx: SharedBuildContext,
    discovery: *Module.DiscoveryContext,
) !*std.Build.Module {
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
    try Module.wireAll(b, root_mod, &discovery.modules, &discovery.source_paths, shared_ctx);
    try SystemLibraries.loadLinks(b);
    SystemLibraries.link(root_mod);
    // Discovered modules don't inherit root_mod's include/library paths, so
    // give each one the same system paths for its @cImport / link work.
    var mod_it = discovery.modules.valueIterator();
    while (mod_it.next()) |mod| {
        // All discovered modules are compiled into the libc-linked `hana`
        // binary; see finalizeModuleLinked for why libc is declared per module.
        finalizeModuleLinked(mod.*, optimize, has_usr);
    }
    return root_mod;
}

/// Unit-test wiring (src/test/**): every discovered *_test module becomes a
/// `zig build test` run (and a `zig build test.<stem>` single-file step),
/// gated by its own `// build-gate:` line; X-gated tests are serialized on
/// one $DISPLAY. Returns the aggregate `test` step.
fn wireUnitTests(
    b: *std.Build,
    discovery: *Module.DiscoveryContext,
    features: FeatureSet,
    test_filter: ?[]const u8,
) !*std.Build.Step {
    // Tests must run through the build rather than a bare `zig test <file>`:
    // discovered modules are cross-wired by real import edges, and a
    // standalone invocation cannot resolve the named imports (model, helpers,
    // ...) that production builds resolve.
    const unit_test_step = b.step("test", "Run unit tests");
    // Feature gates, derived: the table lives with FeatureSet so the test
    // reader and the plugin specs cannot disagree about what exists.
    const feature_flags = features.featureFlags();

    // X-gated integration tests connect to the same $DISPLAY; chain their run
    // steps so server-global input-focus assertions cannot race across the
    // parallel test processes.
    var x_gated_run: ?*std.Build.Step = null;
    // Presence in this table = the test is X-gated: it shares $DISPLAY with
    // the other entries and must be serialized (see x_gated_run below).
    //
    // X-gating belongs in the build because it genuinely is a property of the
    // build, not of the file: these tests share one $DISPLAY and the runner
    // must serialize them, which no line in the test's own source can express.
    // Feature gating is the opposite case and lives in each test file
    // (`// build-gate: tiling, seg_prompt`), next to the imports that
    // constrain it, so gate and imports cannot drift apart.
    const test_gates = [_][]const u8{
        "actions_test",
        "ewmh_test",
        "focus_test",
        "pipeline_test",
        "visibility_test",
        "borders_test",
    };
    {
        // The discovered *_test set; every test_gates row must appear in it.
        var discovered = std.StringHashMap(void).init(b.allocator);
        defer discovered.deinit();
        var discover_it = discovery.modules.iterator();
        while (discover_it.next()) |entry| {
            if (std.mem.endsWith(u8, entry.key_ptr.*, "_test"))
                try discovered.put(entry.key_ptr.*, {});
        }
        // A row left behind by a renamed or deleted test file would sit silent
        // forever: nothing wires it, so the mistake would surface nowhere.
        for (test_gates) |g| {
            if (!discovered.contains(g)) {
                std.debug.print(
                    "build: test_gates row '{s}' has no discovered *_test module; remove or rename it\n",
                    .{g},
                );
                return error.StaleTestGate;
            }
        }
        // Iterate a SORTED stem list, not the discovery map's iterator:
        // map order is unspecified, so the order test binaries are created in
        // -- and therefore the order the X-gated chain below is assembled in
        // -- would vary between runs. Correctness is unaffected (the chain
        // serializes either way), but "which X test ran first" has to be
        // reproducible to bisect a flaky integration test.
        var stems: std.ArrayList([]const u8) = .empty;
        defer stems.deinit(b.allocator);
        var discover2 = discovery.modules.iterator();
        while (discover2.next()) |entry| {
            if (std.mem.endsWith(u8, entry.key_ptr.*, "_test")) {
                try stems.append(b.allocator, entry.key_ptr.*);
            }
        }
        std.mem.sort([]const u8, stems.items, {}, lessStrings);

        var filter_matched = false;
        for (stems.items) |stem| {
            const entry = discovery.modules.getPtr(stem).?;
            // X-gating is read from the table above; the FEATURE gate comes
            // from the test's own `// build-gate:` line, sitting next to the
            // imports that make it necessary. Absence from the X table just
            // means "not X-gated".
            const x_gated = for (test_gates) |g| {
                if (std.mem.eql(u8, stem, g)) break true;
            } else false;
            const rel = discovery.source_paths.get(stem) orelse
                return error.NoTestSourcePath;
            const gate = try readTestGate(b, rel, &feature_flags);
            if (!gate.on) continue;
            // -Dtest-filter=<stem> restricts the run to one file while
            // developing. filter_matched makes an unmatched name a loud error
            // rather than a green run of nothing -- a typo would otherwise look
            // exactly like a passing suite.
            if (test_filter) |want| {
                if (!std.mem.eql(u8, stem, want)) continue;
                filter_matched = true;
            }
            // Every test root links the same system libraries as the main
            // exe: modules reached from a test graph may call X11/cairo
            // directly (window, drawing, ...) and get no linkage second-hand
            // from a blanket cross-wire.
            SystemLibraries.link(entry.*);
            const t = b.addTest(.{ .root_module = entry.* });
            const run = b.addRunArtifact(t);
            // Each run step is individually named, so
            // `zig build test.<stem>` runs exactly one file.
            const one_name = std.fmt.allocPrint(b.allocator, "test.{s}", .{stem}) catch @panic("oom");
            const one_desc = std.fmt.allocPrint(b.allocator, "Run only {s}.zig", .{stem}) catch @panic("oom");
            b.step(one_name, one_desc).dependOn(&run.step);
            unit_test_step.dependOn(&run.step);
            if (x_gated) {
                if (x_gated_run) |prev| run.step.dependOn(prev);
                x_gated_run = &run.step;
            }
        }
        if (test_filter != null and !filter_matched) {
            std.debug.print("build: -Dtest-filter='{s}' matched no discovered, ungated *_test module", .{test_filter.?});
            return error.NoSuchTestFilter;
        }
    }
    return unit_test_step;
}

/// The hana executable + the `run` step.
fn buildExeAndRunStep(b: *std.Build, root_mod: *std.Build.Module) *std.Build.Step {
    const exe = b.addExecutable(.{ .name = "hana", .root_module = root_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run hana").dependOn(&run_cmd.step);
    return &exe.step;
}

/// The `bench` step: full-iteration latency/benchmark runs under -Dbench.
fn wireBenchStep(b: *std.Build, bench_enabled: bool, unit_test_step: *std.Build.Step) void {
    // Timings go to `.zig-cache/bench/timings.txt` (see helpers.benchLog)
    // rather than to stderr: the test protocol treats ANY stderr as a failed
    // command, so printing them there would fail a fully passing suite. The
    // step FAILS LOUDLY when the flag is absent instead of silently running
    // the cheap smoke loops -- a discoverable step name that quietly does
    // something else is worse than an error.
    const bench_step = b.step("bench", "Run latency/benchmark tests (requires -Dbench=true)");
    if (bench_enabled) {
        bench_step.dependOn(unit_test_step);
    } else {
        bench_step.dependOn(&b.addFail("zig build bench requires -Dbench=true; without it the bench tests are smoke runs and the step would silently do nothing useful").step);
    }
}

/// Plugin-template compile gate + the `check` / `check-modularity` /
/// `check-all` steps.
fn wireCheckSteps(
    b: *std.Build,
    exe_step: *std.Build.Step,
    discovery: *Module.DiscoveryContext,
    features: FeatureSet,
    shared_ctx: SharedBuildContext,
    has_usr: UsrDirs,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !void {
    // Plugin-template compile gate: dev/plugin-template/** is compiled against
    // the real discovered modules (cross-wired like an in-tree module), so the
    // drop-in templates can't drift from current contracts without
    // `zig build check-plugin-template` (and by extension `zig build check`)
    // failing. Each template is only compiled when its imports are present.
    const plugin_template_specs = [_]PluginTemplateSpec{
        .{ .path = "dev/plugin-template/layout.zig", .import = "layout", .present = features.has_tiling },
        .{ .path = "dev/plugin-template/provider.zig", .import = "provider", .present = true },
        .{ .path = "dev/plugin-template/segment.zig", .import = "segment", .present = features.has_bar },
        // Sub-addon templates: each imports its package core's
        // contract type, so it is compiled only while that core
        // is discovered (a removed package would otherwise fail
        // the template's import).
        .{ .path = "dev/plugin-template/readout.zig", .import = "readout", .decl = "sub", .present = features.has_seg_systatus },
        .{ .path = "dev/plugin-template/control.zig", .import = "control", .decl = "sub", .present = features.has_seg_slider },
        .{ .path = "dev/plugin-template/title-addon.zig", .import = "title_addon", .decl = "addon", .present = features.has_seg_title },
        .{ .path = "dev/plugin-template/prompt-addon.zig", .import = "prompt_addon", .decl = "addon", .present = features.has_seg_prompt },
    };
    const plugin_template_check = try buildPluginTemplateCheck(b, &discovery.modules, shared_ctx, has_usr, target, optimize, &plugin_template_specs);
    // `zig build check` type-checks the exe AND runs the layer guards
    // (check-layers.sh): the pure layers stay xcb-free and wire-mutating
    // requests stay behind the reconcile boundary.
    const check_step = b.step("check", "Type-check + layer guards");
    check_step.dependOn(exe_step);
    const layers = b.addSystemCommand(&.{"./dev/scripts/check-layers.sh"});
    layers.step.dependOn(exe_step);
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

/// Generated source for the chrome-surface (bar) registration module. A hook
/// set rather than a module registry, so it is kept apart from the per-owner
/// `modules` registries.
const surfaces_generated_source =
    \\const build_options = @import("build_options");
    \\const core = @import("core");
    \\const xcb = core.xcb;
    \\const types = @import("types");
    \\
    \\// No-op hooks for a build with no surface module compiled in. The point
    \\// of a real struct rather than `null` is that `Surfaces` is then ONE
    \\// type in every build: core never tests a build flag before calling a
    \\// hook, so a hook ADDED to the contract cannot be forgotten at a call
    \\// site in some builds and guarded in others. These bodies are trivial,
    \\// so the unused surface really does no work.
    \\fn noopVoid() void {}
    \\fn noopBool() bool {
    \\    return false;
    \\}
    \\fn noopKeypress(_: *const xcb.xcb_key_press_event_t, _: ?*const types.Action) bool {
    \\    return false;
    \\}
    \\fn noopExpose(_: *const xcb.xcb_expose_event_t) void {}
    \\fn noopButtonPress(_: *const xcb.xcb_button_press_event_t) void {}
    \\fn noopButtonMotion(_: *const xcb.xcb_motion_notify_event_t) void {}
    \\fn noopButtonRelease(_: *const xcb.xcb_button_release_event_t) void {}
    \\fn noopAction(_: types.Action) void {}
    \\fn noopU8(_: u8) void {}
    \\fn noopTimeout() i32 {
    \\    return -1;
    \\}
    \\fn noopWin(_: u32) bool {
    \\    return false;
    \\}
    \\fn noopInit() anyerror!void {}
    \\
    \\/// The active chrome-surface hook set. With no surface module compiled
    \\/// in, every hook is the no-op above; with one, the module's own set.
    \\pub const Surfaces = if (build_options.has_bar) @import("bar").surfaces else .{
    \\    .init = noopInit,
    \\    .deinit = noopVoid,
    \\    .handleExpose = noopExpose,
    \\    .updateIfDirty = noopVoid,
    \\    .pollTimeoutMs = noopTimeout,
    \\    .onPollWakeup = noopVoid,
    \\    .updateClock = noopVoid,
    \\    .onReload = noopVoid,
    \\    .chromeHandleKeypress = noopKeypress,
    \\    .isBarWindow = noopWin,
    \\    .handleButtonPress = noopButtonPress,
    \\    .handleButtonMotion = noopButtonMotion,
    \\    .handleButtonRelease = noopButtonRelease,
    \\    .setBarState = noopAction,
    \\    .updateBarVisibilityForWorkspace = noopU8,
    \\    .hideBarForFullscreen = noopVoid,
    \\    .toggleBarSegmentAnchor = noopVoid,
    \\    // null, not a no-op function: with no bar there is no
    \\    // fullscreen-forces-bar-hidden predicate to answer, and the
    \\    // `Surfaces` value is a compile-time choice anyway. Listed here
    \\    // for the same reason every other hook is -- a hook added to the
    \\    // contract cannot be forgotten in the no-bar build.
    \\    .barForcedHiddenByFullscreen = null,
    \\    .chromeToggleOverlay = noopVoid,
    \\};
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

/// Generates the build-owned `surfaces` module alongside its source file, and
/// returns the module to inject everywhere via `injectShared`.
///
/// This is the single seam concentrating core's coupling to chrome surfaces.
/// The source is written at build time via `addWriteFiles` and exposed as a
/// normal module (`b.createModule`), so nothing about it is committed. The
/// generated module is deliberately given only the imports its source
/// references (unlike discovered modules, which are cross-wired with
/// everything).
fn buildSurfacesModule(
    b: *std.Build,
    discovered: *std.StringHashMap(*std.Build.Module),
    build_opts: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    // The no-op hook set needs `core` and `types` for its parameter types
    // (xcb comes from core's re-export), so both are registered up front --
    // the generated source is analyzed for its signatures whether or not a
    // surface module is present.
    const mod = makeGeneratedModule(b, target, optimize, "surfaces.zig", surfaces_generated_source, &[_]Import{
        .{ .name = "build_options", .module = build_opts },
        .{ .name = "core", .module = discovered.get("core").? },
        .{ .name = "types", .module = discovered.get("types").? },
    });
    // The chrome-surface module is referenceable (`@import("bar")`) only when
    // its source was discovered; the comptime has_bar guard keeps the
    // no-registration case from ever being analyzed.
    if (discovered.get("bar")) |m| mod.addImport("bar", m);
    return mod;
}

/// Generates the build-owned `tiling_seam` module alongside its source file,
/// and returns the module to register under that name.
///
/// The seam names the tiling subsystem (or an inert empty struct when the
/// tiling directory is gone). Core and input layers import the seam, never
/// src/tiling/ by name; removing the tiling subsystem therefore can't leave
/// a named import dangling in sync/pipeline/actions/input, because the
/// absent case is an empty type reached only behind `has_tiling` gates.
fn buildTilingSeamModule(
    b: *std.Build,
    discovered: *std.StringHashMap(*std.Build.Module),
    build_opts: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const source =
        \\const build_options = @import("build_options");
        \\const model = @import("model");
        \\
        \\/// The tiling subsystem behind a build-time seam: core and input layers
        \\/// import this module, never src/tiling/ by name. When the tiling
        \\/// subsystem is absent the binding is an inert empty type (every member
        \\/// reference sits behind a build_options.has_tiling gate).
        \\/// Generated by build.zig; never committed.
        \\pub const tiling = if (build_options.has_tiling) @import("tiling") else struct {};
        \\
        \\/// Tiling-order operations, forwarded to the engine when present and
        \\/// inert no-ops when the tiling subsystem is absent. Hub call sites
        \\/// (window admission/sync, tests) reach the ops through the seam so
        \\/// they need no per-call `has_tiling` guard of their own.
        \\pub fn reorderTiled(m: *model.Model, win: model.WindowId, idx: usize) void {
        \\    if (build_options.has_tiling) tiling.reorderTiled(m, win, idx);
        \\}
        \\pub fn stepTiled(m: *model.Model, win: model.WindowId, dir: i32) void {
        \\    if (build_options.has_tiling) tiling.stepTiled(m, win, dir);
        \\}
        \\pub fn swapPrimary(m: *model.Model) void {
        \\    if (build_options.has_tiling) tiling.swapPrimary(m);
        \\}
        \\pub fn swapFocusedWithPrevious(m: *model.Model) void {
        \\    if (build_options.has_tiling) tiling.swapFocusedWithPrevious(m);
        \\}
        \\pub fn adjustPrimaryWidth(m: *model.Model, delta: f32) void {
        \\    if (build_options.has_tiling) tiling.adjustPrimaryWidth(m, delta);
        \\}
    ;
    const mod = makeGeneratedModule(b, target, optimize, "tiling_seam.zig", source, &[_]Import{
        .{ .name = "build_options", .module = build_opts },
        .{ .name = "model", .module = discovered.get("model").? },
    });
    if (discovered.get("tiling")) |m| mod.addImport("tiling", m);
    return mod;
}

/// One discovered config fragment: the `<owner>_config` stem and its owner
/// module name (the `composed.Config` field name).
const ConfigFragment = struct {
    owner: []const u8,
    stem: []const u8,
};

/// Discovers every `*_config` fragment on the src/ walk (skipping the
/// reserved `composed` name and the always-present `core_config`, which the
/// composed module dispatches by name rather than field). Each fragment's
/// owner (the stem minus `_config`) must be a discovered module -- a fragment
/// without its subsystem is a build error, not a silent drop. Sorted by owner
/// so the generated parse/deinit order is deterministic.
fn discoverConfigFragments(
    b: *std.Build,
    discovery: *const Module.DiscoveryContext,
) ![]ConfigFragment {
    var list: std.ArrayList(ConfigFragment) = .empty;
    var it = discovery.source_paths.iterator();
    while (it.next()) |entry| {
        const stem = entry.key_ptr.*;
        if (!std.mem.endsWith(u8, stem, "_config")) continue;
        if (std.mem.eql(u8, stem, "composed")) continue;
        // Not a config fragment despite the stem: `core_config` is the
        // always-present core fragment the facade dispatches by name, and
        // `model_config` is the reload/boot SEEDING root (config→model param
        // stamping), which owns no Config struct at all.
        if (std.mem.eql(u8, stem, "core_config")) continue;
        if (std.mem.eql(u8, stem, "model_config")) continue;
        const owner = stem[0 .. stem.len - "_config".len];
        if (owner.len == 0) continue;
        if (!discovery.modules.contains(owner)) {
            std.debug.print(
                "Error: config fragment '{s}' ({s}) has no owning module '{s}'. Rename or delete the file.\n",
                .{ stem, entry.value_ptr.*, owner },
            );
            return error.OrphanConfigFragment;
        }
        try list.append(b.allocator, .{
            .owner = try b.allocator.dupe(u8, owner),
            .stem = try b.allocator.dupe(u8, stem),
        });
    }
    std.mem.sort(ConfigFragment, list.items, {}, struct {
        fn less(_: void, a: ConfigFragment, b_: ConfigFragment) bool {
            return std.mem.lessThan(u8, a.owner, b_.owner);
        }
    }.less);
    return list.toOwnedSlice(b.allocator);
}

/// Generates the build-owned `composed` config facade alongside its source
/// file, and returns the module to register under that name.
///
/// The facade is the top-level `Config` (the old monolithic types.Config),
/// assembled from the always-present `core_config` plus every discovered
/// `<owner>_config` fragment: one field, one parse/validate call, one deinit
/// call per fragment. Deleting an optional subsystem deletes its fragment
/// file, which regenerates a shorter struct -- the field and every call
/// vanish, so no config trace of the module survives. The fragment contract
/// (Config/parse/validate/deinit) is uniform, so the generator never names a
/// subsystem.
fn buildComposedModule(
    b: *std.Build,
    discovered: *std.StringHashMap(*std.Build.Module),
    fragments: []const ConfigFragment,
    build_opts: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    var src: std.ArrayList(u8) = .empty;

    src.appendSlice(b.allocator,
        \\//! The composed config: the top-level `Config` assembled from the
        \\//! discovered `*_config` fragments plus the always-present
        \\//! `core_config`. Generated by build.zig; never committed. Deleting an
        \\//! optional subsystem regenerates a shorter struct: the fragment's
        \\//! field, parse/validate calls and deinit call simply vanish, leaving
        \\//! zero config trace of the removed module.
        \\//!
        \\//! Fragment contract (every `<owner>_config` module must export):
        \\//!   `Config`   -- the subsystem config struct (field defaults seed)
        \\//!   `parse`    -- `fn (std.mem.Allocator, *parser.Document) !Config`
        \\//!   `validate` -- `fn (*const Config) !void` (error.InvalidConfig
        \\//!                 fails the load; warn-and-continue stays in parse)
        \\//!   `deinit`   -- method on Config
        \\//!
        \\//! Every field is a NON-optional with a `= .{}` default: an absent
        \\//! fragment omits the field entirely rather than carrying an
        \\//! optional payload the whole tree would test (the C4 disposition).
        \\
        \\const std = @import("std");
        \\const types = @import("types");
        \\const parser = @import("parser");
        \\const color = @import("color");
        \\const core_config = @import("core_config");
        \\
    ) catch unreachable;
    for (fragments) |f| {
        src.print(b.allocator, "const {s} = @import(\"{s}\");\n", .{ f.stem, f.stem }) catch unreachable;
    }

    src.appendSlice(b.allocator,
        \\
        \\pub const Config = struct {
        \\    core: types.CoreConfig = .{},
        \\
    ) catch unreachable;
    for (fragments) |f| {
        src.print(b.allocator, "    {s}: {s}.Config = .{{}},\n", .{ f.owner, f.stem }) catch unreachable;
    }

    src.appendSlice(b.allocator,
        \\
        \\    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        \\        self.core.deinit(allocator);
        \\
    ) catch unreachable;
    for (fragments) |f| {
        src.print(b.allocator, "        self.{0s}.deinit(allocator);\n", .{f.owner}) catch unreachable;
    }
    src.appendSlice(b.allocator,
        \\    }
        \\
        \\};
        \\
        \\/// Assembles a Config from a parsed document: palette first (color knobs
        \\/// may reference the reserved variables), then the always-present core
        \\/// fragment, then each discovered fragment in owner order. An
        \\/// `error.InvalidConfig` from any validate fails the whole load (boot
        \\/// falls back; reload keeps the live config); the errdefer tears down
        \\/// whatever was assembled so far. An empty document yields the same
        \\/// defaults the old `getDefaultConfig` seeded, because every fragment
        \\/// self-seeds its owned non-scalars and its scalars come from field
        \\/// initializers.
        \\pub fn parse(allocator: std.mem.Allocator, doc: *parser.Document) !Config {
        \\    var cfg: Config = .{};
        \\    errdefer cfg.deinit(allocator);
        \\    color.collectPalette(doc);
        \\    cfg.core = try core_config.parse(allocator, doc);
        \\    try core_config.validate(&cfg.core);
        \\
    ) catch unreachable;
    for (fragments) |f| {
        src.print(
            b.allocator,
            "    cfg.{0s} = try {1s}.parse(allocator, doc);\n" ++
                "    try {1s}.validate(&cfg.{0s});\n\n",
            .{ f.owner, f.stem },
        ) catch unreachable;
    }
    src.appendSlice(b.allocator,
        \\    return cfg;
        \\}
        \\
    ) catch unreachable;

    var imports: std.ArrayList(Import) = .empty;
    imports.append(b.allocator, .{ .name = "build_options", .module = build_opts }) catch unreachable;
    imports.append(b.allocator, .{ .name = "types", .module = discovered.get("types").? }) catch unreachable;
    imports.append(b.allocator, .{ .name = "parser", .module = discovered.get("parser").? }) catch unreachable;
    imports.append(b.allocator, .{ .name = "color", .module = discovered.get("color").? }) catch unreachable;
    imports.append(b.allocator, .{ .name = "core_config", .module = discovered.get("core_config").? }) catch unreachable;
    for (fragments) |f| {
        imports.append(b.allocator, .{ .name = f.stem, .module = discovered.get(f.stem).? }) catch unreachable;
    }
    return makeGeneratedModule(b, target, optimize, "composed.zig", src.items, imports.items);
}

/// Drops the `[section]` blocks whose owning subsystem is absent from the
/// embedded fallback TOML text. The fallback is shared source for every
/// modularity shape (a no-bar tree still embeds the same file), so without
/// this filter a no-bar build would parse `[bar...]` sections into an
/// unconsumed-key warning storm. Line-oriented: a section line starts a run;
/// every following line belongs to it until the next section line. The
/// fallback carries no multi-line arrays, so a line is a safe unit. Returns
/// `toml` unchanged when present sections all map to present modules; null
/// stays null.
fn filterFallbackToml(
    b: *std.Build,
    toml: ?[]const u8,
    discovery: *const Module.DiscoveryContext,
) ?[]const u8 {
    const raw = toml orelse return null;
    var out: std.ArrayList(u8) = .empty;
    var keep = true;
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0 and trimmed[0] == '[') {
            const close = std.mem.indexOfScalar(u8, trimmed, ']') orelse trimmed.len;
            const section = std.mem.trim(u8, trimmed[1..close], " \t");
            keep = fallbackSectionAllowed(section, discovery);
        }
        if (keep) out.appendSlice(b.allocator, line) catch return raw;
        out.append(b.allocator, '\n') catch return raw;
    }
    return out.items;
}

/// True when the fallback's `[section]` (or its family prefix) belongs to a
/// subsystem present in this tree. The FIRST dotted component picks the
/// owner: `tiling.*`, `bar.*` (incl. bar.properties/layout/modules),
/// `workspaces`/`workspace.rules.*`/`rules.*` -> workspaces, `drag` ->
/// floating. Unrecognized sections always stay (core-owned vocabulary).
fn fallbackSectionAllowed(section: []const u8, discovery: *const Module.DiscoveryContext) bool {
    const dot = std.mem.indexOfScalar(u8, section, '.');
    const head = if (dot) |d| section[0..d] else section;
    const owner = if (std.mem.eql(u8, head, "tiling")) "tiling" else if (std.mem.eql(u8, head, "bar")) "bar" else if (std.mem.eql(u8, head, "workspaces")) "workspaces" else if (std.mem.eql(u8, head, "workspace")) "workspaces" else if (std.mem.eql(u8, head, "rules")) "workspaces" else if (std.mem.eql(u8, head, "drag")) "floating" else return true;
    return discovery.modules.contains(owner);
}

/// The per-owner stem registry for every `modules/` directory.
///
/// Each `modules/` dir is a set of pluggable sub-systems; the owner is the
/// parent directory. Stems are harvested during the single `src/` walk in
/// `DiscoveryContext.discoverAll` and sorted here for deterministic dispatch.
const OwnerRegistry = struct {
    /// Owner -> its registry stems, restricted to files that SELF-DECLARE the
    /// owner's module binding (`pub const module`). A package core without one
    /// (systatus, slider: no aggregate belt module) drops out of the owner
    /// registry and reaches `bar_modules` only through its derived
    /// `segmentFor(i)` entries.
    owners: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .{},

    /// owner name -> the `contract.*` contract its modules bind (`window` ->
    /// WindowModule, `bar` -> Segment, `tiling` -> Layout). Derived from each
    /// owner's module files by `deriveOwnerContracts` (no hand table to
    /// drift from the modules' actual declarations).
    contracts: std.StringArrayHashMapUnmanaged([]const u8) = .{},

    /// Populates the registry from the walk's `owner_stems` map, converting it
    /// to sorted per-owner lists for deterministic dispatch order.
    fn run(discovery: *const Module.DiscoveryContext) !OwnerRegistry {
        var reg = OwnerRegistry{};
        var it = discovery.owner_stems.iterator();
        while (it.next()) |entry| {
            const dup_owner = try discovery.b.allocator.dupe(u8, entry.key_ptr.*);
            var list = std.ArrayListUnmanaged([]const u8).empty;
            for (entry.value_ptr.items) |stem| {
                // Only files SELF-DECLARING the owner's module binding
                // (`pub const module`) are registry members; the walk's
                // memoized classification answers that without re-reading the
                // file. A core without the binding contributes to `bar_modules`
                // as standalone `segmentFor(i)` entries instead (see
                // `ownerModuleEntries`).
                const rel_path = discovery.source_paths.get(stem) orelse continue;
                // The walk classified every owner-tree file (one read); a stem
                // without a record is skipped defensively.
                const fc = discovery.classified.get(rel_path) orelse continue;
                if (!fc.pub_module) continue;
                try list.append(discovery.b.allocator, stem);
            }
            try reg.owners.put(discovery.b.allocator, dup_owner, list);
        }
        for (reg.owners.values()) |*list| {
            std.mem.sort([]const u8, list.items, {}, lessStrings);
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
    sub_specs: []const SubRegistrySpec,
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
    for (sub_specs) |spec| {
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

/// The one shared build-time source scanner: a bounded read of a source file
/// into a buffer the struct owns, plus the line iteration every line-oriented
/// scan in this file consumes (module classification, binding declarations,
/// subs-registry discovery, test gates, import edges), so the read bound
/// (`max_scan_source_bytes`) and the read/free pairing live in one place.
const SourceScanner = struct {
    b: *std.Build,
    src: []const u8,

    /// Bounded read: the scanned decls (a `pub const module` shape, a binding
    /// marker, a build-gate line, an @import literal) all live in the first
    /// few hundred bytes of a file, and a build script is not a place to
    /// allocate an unbounded read for.
    fn open(b: *std.Build, rel_path: []const u8) !SourceScanner {
        return .{
            .b = b,
            .src = try b.build_root.handle.readFileAlloc(
                b.graph.io,
                rel_path,
                b.allocator,
                .limited(Module.max_scan_source_bytes),
            ),
        };
    }

    fn close(self: SourceScanner) void {
        self.b.allocator.free(self.src);
    }

    /// Line iterator over the scanned source: splits on newlines
    /// and trims horizontal whitespace (and a trailing CR) per
    /// line, the shape every line-oriented scan consumes.
    fn lines(self: SourceScanner) LineIterator {
        return .{ .rest = self.src };
    }
};

const LineIterator = struct {
    rest: []const u8,

    fn next(self: *LineIterator) ?[]const u8 {
        if (self.rest.len == 0) return null;
        const nl = std.mem.indexOfScalar(u8, self.rest, '\n') orelse self.rest.len;
        const line = std.mem.trim(u8, self.rest[0..nl], " \t\r");
        self.rest = if (nl == self.rest.len) self.rest[nl..] else self.rest[nl + 1 ..];
        return line;
    }
};

/// The registry element type per owner is DERIVED from each owner's module
/// files instead of a hand-maintained table, so the generated
/// `<owner>_modules` typing cannot drift from the contracts the modules
/// actually bind to. `classifyFile` scans each file ONCE (source reads are a
/// single-pass: the walk's reservation and this derivation share the memoized
/// classification, see `DiscoveryContext.ensureClassified`). Three declaration
/// shapes are recognized, all yielding the `contract.*` contract the file
/// binds its `module` value to:
///
///   1. `pub const module: @import("<owner>_contract").<Contract> = ...` — the
///      typed form used by the window sub-systems (floating, fullscreen,
///      minimize, workspaces) and the plugin-template provider; the bar
///      segments and tiling layouts use the shim forms below. The import is
///      the per-engine contract module: `window_contract`, `bar_contract`, or
///      `tiling_contract`.
///   2. `pub const module = <alias>.module(...)` — the segment-binding
///      builder shim (clock, layout, variants); `<alias>.module` returns
///      `contract.Segment` by construction, so the contract is the same
///      name. The alias is whatever the file binds the segment module to
///      (in-tree: `segmod`), so the check matches any local identifier.
///   3. `pub const module = <alias>.layoutModule(...)` — the tiling
///      layouts; `<alias>.layoutModule` returns `contract.Layout` by
///      construction.
///
/// A module file declaring `pub const module` in ANOTHER shape (a bare alias
/// or a foreign shim) is a LOUD build error — the generated registry would
/// otherwise mis-type its `module` value against a sibling's contract.
fn classifyFile(b: *std.Build, rel_path: []const u8) !Module.FileClass {
    var scan = try SourceScanner.open(b, rel_path);
    defer scan.close();

    const typed_needles = [_][]const u8{
        "pub const module: @import(\"window_contract\").",
        "pub const module: @import(\"bar_contract\").",
        "pub const module: @import(\"tiling_contract\").",
    };
    const shim_prefix = "pub const module = ";
    // Any `pub const module` declaration in an unrecognized spelling.
    const module_needle = "pub const module";
    var saw_unrecognized: bool = false;
    var it = scan.lines();
    while (it.next()) |trimmed| {
        // Skip doc/comments: a mentioning of `pub const module` inside a doc
        // line (an example or a cross-reference) would otherwise trip the
        // same saw_unrecognized / wrong-shape guard declaresBinding already
        // escapes with.
        if (std.mem.startsWith(u8, trimmed, "//")) continue;
        for (typed_needles) |typed_needle| {
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
                if (n == 0) {
                    saw_unrecognized = true;
                    continue;
                }
                return .{ .pub_module = true, .contract = try b.allocator.dupe(u8, rest[0..n]) };
            }
        }
        // Shim forms: `pub const module = <alias>.module(...)` (Segment) or
        // `<alias>.layoutModule(...)` (Layout). The alias is file-local
        // (whichever name the file binds the builder module to), so parse
        // the identifier and match the call it dispatches to.
        if (std.mem.startsWith(u8, trimmed, shim_prefix)) {
            const rest = trimmed[shim_prefix.len..];
            var n: usize = 0;
            while (n < rest.len) : (n += 1) {
                const c = rest[n];
                const is_name_char = (c >= 'a' and c <= 'z') or
                    (c >= 'A' and c <= 'Z') or
                    (c >= '0' and c <= '9');
                if (!is_name_char) break;
            }
            if (n > 0) {
                const after = rest[n..];
                if (std.mem.startsWith(u8, after, ".module("))
                    return .{ .pub_module = true, .contract = "Segment" };
                if (std.mem.startsWith(u8, after, ".layoutModule("))
                    return .{ .pub_module = true, .contract = "Layout" };
            }
            saw_unrecognized = true;
            continue;
        }
        if (std.mem.indexOf(u8, trimmed, module_needle) != null)
            saw_unrecognized = true;
    }
    if (saw_unrecognized) {
        std.debug.print(
            "Error: module '{s}' declares `pub const module` in an unrecognized shape; bind one of the typed forms (`pub const module: @import(\"window_contract\").WindowModule = ...`, `pub const module: @import(\"bar_contract\").Segment = ...`, `pub const module: @import(\"tiling_contract\").Layout = ...`, `pub const module = <alias>.module(...)`, or `pub const module = <alias>.layoutModule(...)`).\n",
            .{rel_path},
        );
        return error.UnrecognizedModuleSpelling;
    }
    return .{};
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

/// Fills `registry.contracts` (owner -> contract name) from the OWNER's
/// module files' memoized classifications (see `DiscoveryContext.ensureClassified`
/// and `classifyFile`): every module must agree on the contract, and at least
/// one module must declare one. An owner whose `modules/` tree holds ZERO
/// modules binds a default: an empty registry binds no module values, so its
/// element type is consumer-binding metadata (the typed `[]const contract.X` a
/// core tier casts the empty array to), not a module-declared contract —
/// nothing exists to derive it from, and only the three known owners can ever
/// appear empty (`window` when every behavior module is removed).
fn deriveOwnerContracts(
    b: *std.Build,
    discovery: *const Module.DiscoveryContext,
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
            const rel_path = discovery.source_paths.get(stem) orelse continue;
            // The walk classified every owner-tree file (one read); a stem
            // without a record can't declare a contract.
            const fc = discovery.classified.get(rel_path) orelse continue;
            const c = fc.contract orelse continue;
            if (contract) |known| {
                if (!std.mem.eql(u8, known, c)) {
                    std.debug.print(
                        "Error: owner '{s}' binds mixed contracts: '{s}' (via {s}) vs '{s}' (via {s}). All modules in a <owner>/modules/ tree must bind the same contract.\n",
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

/// One generated `<package>_subs` sub-addon registry, derived from what the
/// tree imports instead of from a hand-written table: a package gets a spec
/// when any discovered module reads `@import("<package>_subs").<array>` --
/// the package core's own re-export (`pub const subs =
/// @import("systatus_subs").subs`) or a private sibling reading the array
/// (`slider/shell.zig`). Everything else on the spec follows from that import
/// plus the package core's declarations (see the field docs).
///
/// A directory is NOT a family by itself: only a real `_subs` read makes a
/// registry exist, so a `modules/` subdir whose files merely coexist gets no
/// registry, no array, and no binding to miss. src/bar/modules/layout/ is the
/// worked example -- layout.zig (the icon) and variants.zig (the text) are two
/// independent segments sharing a subject, each registered on its own, so
/// deleting one changes nothing about the other. Because membership is one
/// bounded source scan plus file presence, deleting a bound sibling only
/// regenerates a shorter array, and deleting the last consumer drops the
/// registry with no dead references left behind.
///
/// Specs sort by package name: that order feeds `bar_modules`' derived
/// segmentFor entries, so it must be deterministic across builds.
const SubRegistrySpec = struct {
    /// The import name minus the `_subs` suffix; must be a discovered module,
    /// because the generated registry imports it back.
    package: []const u8,
    /// The field access after the import: the registry's export name, what
    /// every consumer reads.
    array: []const u8,
    /// `array` without its plural `s` (`subs` -> `sub`, `addons` -> `addon`):
    /// the self-declaring role marker a bound sibling exposes (see
    /// `declaresBinding`).
    binding: []const u8,
    /// `<package>.Binding` -- every package core exports that alias for its
    /// contract struct, so the generated array's element type follows the core
    /// even where the concrete name differs (`Sub`, `Addon`, `Scroller`) or a
    /// sibling imports it under a local alias (`title_mod.Scroller`).
    contract: []const u8,
    /// Packages whose bound subs are promoted to standalone BAR segments: one
    /// `@import("<package>").segmentFor(i)` entry per bound sub is appended to
    /// the generated `bar_modules` registry (see `ownerModuleEntries`), so each
    /// readout/control is individually selectable, orderable, and spaced in
    /// `[bar.layout.*]` rather than riding one aggregate "systatus"/"slider"
    /// belt. The package core exports `pub fn segmentFor(comptime i: usize)
    /// contract.Segment`, and the entry index `i` always equals the sub's index
    /// in the generated `<package>_subs` registry (both consume the same
    /// sorted bound-sub list), so `segmentFor(i)` selects exactly `subs[i]`.
    bar_segments: bool,
};

/// One `@import("<package>_subs").<array>` literal found in a source line.
const SubsConsumer = struct {
    package: []const u8,
    array: []const u8,
};

/// Derives every `SubRegistrySpec` from a bounded scan of the discovered
/// sources: `@import("<package>_subs").<array>` literals name the registries
/// the tree actually consumes (comment lines are skipped, so prose about an
/// import never registers one). Consumers of one package (its core plus a
/// sibling reading the array) dedupe to one spec and must agree on the
/// array. A consumer naming an undiscovered package, a package core missing
/// its `pub const Binding` alias, or a non-plural array is a configure-time
/// error: each would otherwise surface as a raw compile error -- or, for a
/// drifted binding, as a silently empty registry -- far from its cause.
fn discoverSubRegistrySpecs(
    b: *std.Build,
    discovery: *const Module.DiscoveryContext,
) ![]SubRegistrySpec {
    var specs: std.ArrayListUnmanaged(SubRegistrySpec) = .empty;
    var seen = std.StringHashMapUnmanaged(struct { index: usize, consumer: []const u8 }){};
    var consumers: std.ArrayListUnmanaged(SubsConsumer) = .empty;
    var it = discovery.source_paths.iterator();
    while (it.next()) |entry| {
        const rel_path = entry.value_ptr.*;
        consumers.clearRetainingCapacity();
        var scan = try SourceScanner.open(b, rel_path);
        defer scan.close();
        {
            var lines = scan.lines();
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "//")) continue;
                try parseSubsConsumers(b, line, rel_path, &consumers);
            }
        }
        for (consumers.items) |c| {
            const gop = try seen.getOrPut(b.allocator, c.package);
            if (gop.found_existing) {
                const prev = specs.items[gop.value_ptr.index];
                if (!std.mem.eql(u8, prev.array, c.array)) {
                    std.debug.print(
                        "Error: {s} reads '{s}_subs' as '.{s}', but {s} reads it as '.{s}'; one package has one generated array.\n",
                        .{ rel_path, c.package, c.array, gop.value_ptr.consumer, prev.array },
                    );
                    return error.ConflictingSubsArray;
                }
                continue;
            }
            if (!discovery.modules.contains(c.package)) {
                std.debug.print(
                    "Error: {s} imports '{s}_subs', but no module named '{s}' is discovered; the generated registry would import a module that does not exist.\n",
                    .{ rel_path, c.package, c.package },
                );
                return error.UnknownSubsPackage;
            }
            if (c.array.len < 2 or c.array[c.array.len - 1] != 's') {
                std.debug.print(
                    "Error: {s} reads '{s}_subs' as '.{s}'; the array name must be the plural of the sibling binding ('subs'/'addons' -> 'sub'/'addon').\n",
                    .{ rel_path, c.package, c.array },
                );
                return error.NonPluralSubsArray;
            }
            const core_rel = discovery.source_paths.get(c.package).?;
            if (!try declaresBinding(b, core_rel, "Binding")) {
                std.debug.print(
                    "Error: package core {s} does not declare `pub const Binding`; the generated '{s}_subs' array types its elements through that alias.\n",
                    .{ core_rel, c.package },
                );
                return error.MissingSubsBindingAlias;
            }
            try specs.append(b.allocator, .{
                .package = c.package,
                .array = c.array,
                .binding = c.array[0 .. c.array.len - 1],
                .contract = try std.fmt.allocPrint(b.allocator, "{s}.Binding", .{c.package}),
                .bar_segments = try declaresSegmentFor(b, core_rel),
            });
            try seen.put(b.allocator, c.package, .{ .index = specs.items.len - 1, .consumer = rel_path });
        }
    }
    std.mem.sort(SubRegistrySpec, specs.items, {}, struct {
        fn less(_: void, a: SubRegistrySpec, b_: SubRegistrySpec) bool {
            return std.mem.lessThan(u8, a.package, b_.package);
        }
    }.less);
    return specs.items;
}

/// Extracts every `@import("<package>_subs").<array>` literal from `line`,
/// duped into `out` (the scanner's buffer is freed by the caller). A `_subs`
/// import without the inline `.field` access is rejected here: the field IS
/// the registry's export name, so without it neither the array nor the
/// binding can be derived.
fn parseSubsConsumers(
    b: *std.Build,
    line: []const u8,
    rel_path: []const u8,
    out: *std.ArrayListUnmanaged(SubsConsumer),
) !void {
    const needle = "@import(\"";
    var i: usize = 0;
    while (i + needle.len <= line.len) : (i += 1) {
        if (!std.mem.startsWith(u8, line[i..], needle)) continue;
        const name_start = i + needle.len;
        const quote_off = std.mem.indexOfScalar(u8, line[name_start..], '"') orelse {
            i = name_start;
            continue;
        };
        const name = line[name_start .. name_start + quote_off];
        const close = name_start + quote_off + 1;
        if (!std.mem.endsWith(u8, name, "_subs")) {
            i = close;
            continue;
        }
        if (name.len == "_subs".len) {
            std.debug.print(
                "Error: {s} imports the bare '_subs' name; expected \"<package>_subs\".\n",
                .{rel_path},
            );
            return error.BareSubsImport;
        }
        if (close >= line.len or line[close] != ')') {
            i = close;
            continue;
        }
        const dot = close + 1;
        if (dot + 1 > line.len or line[dot] != '.') {
            std.debug.print(
                "Error: {s} imports '{s}' without the inline `.array` field access (e.g. `@import(\"{s}\").subs`); the generated registry's array name comes from it.\n",
                .{ rel_path, name, name },
            );
            return error.SubsWithoutArrayField;
        }
        const field_start = dot + 1;
        var field_end = field_start;
        while (field_end < line.len and isIdentByte(line[field_end])) : (field_end += 1) {}
        if (field_end == field_start) {
            i = dot;
            continue;
        }
        try out.append(b.allocator, .{
            .package = try b.allocator.dupe(u8, name[0 .. name.len - "_subs".len]),
            .array = try b.allocator.dupe(u8, line[field_start..field_end]),
        });
        i = field_end - 1;
    }
}

/// Identifier byte for the `.field` parse in `parseSubsConsumers`.
fn isIdentByte(c: u8) bool {
    return c == '_' or std.ascii.isAlphanumeric(c);
}

/// True when `rel_path` declares the top-level binding `pub const <binding>`
/// -- the self-declaring role marker that turns a package sibling into a
/// bound addon. A sibling WITHOUT the declaration is a private implementation
/// file (native_alsa.zig beside the slider package): still registered as a
/// named module and importable by stem, but excluded from the generated
/// `<package>_subs` registry. Mirrors classifyFile's line-scan: the
/// declaration must be a real top-level decl of the binding name, not a
/// doc-comment reference.
fn declaresBinding(b: *std.Build, rel_path: []const u8, binding: []const u8) !bool {
    var scan = try SourceScanner.open(b, rel_path);
    defer scan.close();
    const needle = try std.fmt.allocPrint(b.allocator, "pub const {s}", .{binding});
    defer b.allocator.free(needle);
    var it = scan.lines();
    while (it.next()) |trimmed| {
        if (std.mem.startsWith(u8, trimmed, "//")) continue;
        if (!std.mem.startsWith(u8, trimmed, needle)) continue;
        const rest = trimmed[needle.len..];
        if (rest.len == 0) continue;
        const next = rest[0];
        if (next == ':' or next == ' ' or next == '=') return true;
    }
    return false;
}

/// True when `rel_path` declares the top-level `pub fn segmentFor` -- the
/// promotion hook a `bar_segments` package core exports so each bound sub
/// reaches `bar_modules` as its own individually-configurable segment (see
/// `SubRegistrySpec.bar_segments`). Comment lines are skipped, mirroring
/// `declaresBinding`.
fn declaresSegmentFor(b: *std.Build, rel_path: []const u8) !bool {
    var scan = try SourceScanner.open(b, rel_path);
    defer scan.close();
    var it = scan.lines();
    while (it.next()) |trimmed| {
        if (std.mem.startsWith(u8, trimmed, "//")) continue;
        if (std.mem.startsWith(u8, trimmed, "pub fn segmentFor")) return true;
    }
    return false;
}

/// Filters one `SubRegistrySpec`'s package siblings to those that
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
    spec: SubRegistrySpec,
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
    std.mem.sortUnstable([]const u8, filtered.items, {}, lessStrings);
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
/// Each registry source lists, in sorted stem order, every discovered
/// sub-system module's `module` value, so core tiers iterate it with uniform
/// loops and never name a sub-system module. The bar registry additionally
/// appends -- AFTER the module-declaring stems, never intermixed -- one
/// `segmentFor(i)` entry per bound sub of each `bar_segments` package (see
/// `SubRegistrySpec`): those packages bind no aggregate belt module, so their
/// readouts/controls reach `bar_modules` only as these derived entries. The
/// generated source is behaviour-identical across presence combinations;
/// deleting a sub-system's file only regenerates a shorter array.
fn buildOwnerRegistries(
    b: *std.Build,
    discovered: *std.StringHashMap(*std.Build.Module),
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    registry: *OwnerRegistry,
    bound_subs: *const std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)),
    sub_specs: []const SubRegistrySpec,
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
            sub_specs,
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
/// package, iterated in `SubRegistrySpec` order (sorted by package name)
/// and, within a package, in the same sorted order as its generated
/// `<package>_subs` registry (`k` == `subs[k]`; both consume
/// `bound_subs`).
fn ownerModuleEntries(
    b: *std.Build,
    is_bar: bool,
    stems: []const []const u8,
    bound_subs: *const std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)),
    sub_specs: []const SubRegistrySpec,
) !std.ArrayListUnmanaged(OwnerEntry) {
    var entries = std.ArrayListUnmanaged(OwnerEntry).empty;
    for (stems) |stem| {
        try entries.append(b.allocator, .{
            .import = stem,
            .expr = try std.fmt.allocPrint(b.allocator, "@import(\"{s}\").module", .{stem}),
        });
    }
    if (is_bar) {
        for (sub_specs) |spec| {
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
/// file. Imports are added only for what the source references: the owner's
/// engine-contract module (wired under the local alias `contract`), every
/// discovered sub-system stem it lists, and -- for a bar registry -- each
/// bar_segments package whose `segmentFor` entries it lists. A stem that
/// isn't discovered can't be listed (the scan walked the real filesystem), so
/// every listed import exists.
fn buildOwnerRegistryModule(
    b: *std.Build,
    discovered: *std.StringHashMap(*std.Build.Module),
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    contract: []const u8,
    entries: []const OwnerEntry,
) !*std.Build.Module {
    // The element contract names which engine-contract module the generated
    // source imports. The source always reaches it through the local alias
    // `contract` (and `contract.<T>`), so only this wiring varies per owner.
    const contract_stem: []const u8 = blk: {
        if (std.mem.eql(u8, contract, "WindowModule")) break :blk "window_contract";
        if (std.mem.eql(u8, contract, "Segment")) break :blk "bar_contract";
        if (std.mem.eql(u8, contract, "Layout")) break :blk "tiling_contract";
        std.debug.print(
            "Error: registry '{s}' derived unknown element contract '{s}' (expected WindowModule, Segment, or Layout).\n",
            .{ name, contract },
        );
        return error.UnknownContract;
    };
    var src = std.ArrayList(u8).empty;
    try src.print(b.allocator, "const contract = @import(\"{s}\");\n\n", .{contract_stem});
    try src.print(b.allocator, "/// The auto-discovered `{s}` sub-system modules, in deterministic\n", .{name});
    try src.print(b.allocator, "/// sorted order (dispatch order == this array's order).\n", .{});
    if (std.mem.eql(u8, name, "bar_modules")) {
        try src.appendSlice(b.allocator, "/// Bar registries additionally list derived standalone segments\n");
        try src.appendSlice(b.allocator, "/// (`segmentFor(i)`, see build.zig `bar_segments`) after the stems.\n");
    }
    try src.appendSlice(b.allocator, "/// Generated by build.zig; never committed.\n");
    try src.print(b.allocator, "pub const modules = [_]contract.{s}{{\n", .{contract});
    for (entries) |e| {
        try src.print(b.allocator, "    {s},\n", .{e.expr});
    }
    try src.print(b.allocator, "}};\n", .{});

    // Registry-wide invariants, enforced at comptime instead of by prose.
    // Both checks key off the DERIVED element contract (never a fixed name),
    // so they follow whatever contract the owner binds: an element type with a
    // `name` identity field gets the uniqueness check (Segment, Layout: config
    // resolves those by name), and an element contract declaring
    // `single_binder_hooks` gets the at-most-one check (WindowModule, Segment:
    // a second first-match binder would be silently ignored).
    try src.appendSlice(b.allocator,
        \\comptime {
        \\    // `modules` is a statically-typed `[_]contract.<T>` array; peel the
        \\    // element contract via the builtin (the generated module imports no
        \\    // std, so no std.meta.Elem here).
        \\    const T = @typeInfo(@TypeOf(modules)).array.child;
        \\    if (@hasField(T, "name")) {
        \\        var names: [modules.len][]const u8 = undefined;
        \\        var n: usize = 0;
        \\        for (modules) |m| {
        \\            for (names[0..n]) |nm| {
        \\                var eql = nm.len == m.name.len;
        \\                if (eql) {
        \\                    var i: usize = 0;
        \\                    while (i < nm.len) : (i += 1) {
        \\                        if (nm[i] != m.name[i]) {
        \\                            eql = false;
        \\                            break;
        \\                        }
        \\                    }
        \\                }
        \\                if (eql and m.name.len != 0)
        \\                    @compileError("duplicate registry name: '" ++ m.name ++ "'");
        \\            }
        \\            if (m.name.len != 0) {
        \\                names[n] = m.name;
        \\                n += 1;
        \\            }
        \\        }
        \\        // A module that persists a window must be NAMED: the save path
        \\        // stamps the claiming module's name so adoption survives a registry
        \\        // reorder, and an unnamed claimant could only fall back to the
        \\        // magic-byte scan for every window it ever saved. Caught here
        \\        // rather than at save time, where it would warn per window.
        \\        if (@hasField(T, "serializeWindow")) {
        \\            for (modules) |wm| {
        \\                if (@field(wm, "serializeWindow") != null and wm.name.len == 0) @compileError(
        \\                    "window module binds serializeWindow but has no name; persistence stamps the claimant name, so an unnamed claimant cannot be fast-pathed",
        \\                );
        \\            }
        \\        }
        \\        // Role capabilities (self_ticking, center_slot) are deliberately
        \\        // multi-binder (fan-out tick / even center split), so no
        \\        // at-most-one assert applies to them.
        \\    }
        \\    // The at-most-one claim is a property of the ELEMENT CONTRACT, so
        \\    // the hook list is looked up on T itself: a `Segment` registry
        \\    // asserts `Segment`'s hooks, a `WindowModule` registry
        \\    // `WindowModule`'s. Looking it up on the `contract` PACKAGE instead
        \\    // would compare one type's fields against another's hook names and
        \\    // could match nothing at all -- enforcing nothing, silently.
        \\    if (@hasDecl(T, "single_binder_hooks")) {
        \\        for (T.single_binder_hooks) |hook| {
        \\            // A name that is not a field of T is a compile error, not a
        \\            // skip: a renamed hook left in the list would otherwise turn
        \\            // the whole claim into a silent no-op.
        \\            if (!@hasField(T, hook)) @compileError(
        \\                "single_binder_hooks lists '" ++ hook ++ "', which is not a field of the registry element type",
        \\            );
        \\            var binders: usize = 0;
        \\            for (modules) |wm| {
        \\                if (@field(wm, hook) != null) binders += 1;
        \\            }
        \\            if (binders > 1)
        \\                @compileError("single-binder hook '" ++ hook ++ "' bound by multiple modules; disallowed");
        \\        }
        \\    }
        \\}
        \\
    );

    const mod = makeGeneratedModule(b, target, optimize, b.fmt("{s}.zig", .{name}), src.items, &[_]Import{});

    if (discovered.get(contract_stem)) |m| mod.addImport(contract_stem, m);
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
/// private siblings (`systatus/{cpu,ram,...}.zig` beside systatus.zig,
/// `prompt/vim.zig` beside prompt.zig, `title/carousel.zig` beside
/// title.zig). Lists every discovered sibling that SELF-DECLARES the binding
/// (`pub const <binding>`) as the package's addon binding value (`sub`,
/// `addon`, ...) in the contract element `contract` (the package core's
/// `Binding` alias), in deterministic alphabetical stem order. A sibling
/// without the binding is a private implementation file and is left out of
/// the registry entirely.
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
    // `sub_stems` arrives pre-sorted from boundSubStems (the one sort that
    // feeds both this registry and segmentFor); no re-sort here, so the two
    // orderings can never diverge.
    var src = std.ArrayList(u8).empty;
    try src.print(b.allocator, "const {s} = @import(\"{s}\");\n\n", .{ package, package });
    try src.print(b.allocator, "/// The auto-discovered {s} sibling add-ons, in\n", .{package});
    try src.appendSlice(b.allocator, "/// deterministic alphabetical order. Generated by build.zig;\n");
    try src.print(b.allocator, "/// never committed. A sibling must export `pub const {s}: {s}` to be\n", .{ binding, contract });
    try src.appendSlice(b.allocator, "/// listed; a sibling without the binding is a private implementation\n");
    try src.appendSlice(b.allocator, "/// file and is left out of the registry. Membership is driven entirely\n");
    try src.appendSlice(b.allocator, "/// by file presence plus self-declared role.\n");
    try src.print(b.allocator, "pub const {s} = [_]{s}{{\n", .{ array_name, contract });
    for (sub_stems) |stem| {
        try src.print(b.allocator, "    @import(\"{s}\").{s},\n", .{ stem, binding });
    }
    try src.appendSlice(b.allocator, "};\n");

    const registry_name = try std.fmt.allocPrint(b.allocator, "{s}_subs.zig", .{package});
    const mod = makeGeneratedModule(b, target, optimize, registry_name, src.items, &[_]Import{});
    if (discovered.get(package)) |m| mod.addImport(package, m);
    for (sub_stems) |stem| {
        if (discovered.get(stem)) |m| mod.addImport(stem, m);
    }
    return mod;
}

/// One feature a test's `// build-gate:` line may name.
const FeatureFlag = struct { name: []const u8, on: bool };

/// A test's self-declared build gate.
///
/// The gate lives in the test file because what decides whether a test CAN
/// compile is which modules it imports -- and the file that knows that is the
/// file itself. The build keeps only what a file cannot know (X-gating; see
/// `wireUnitTests`).
const TestGate = struct {
    /// False when any named feature is absent. Absent marker means ungated.
    on: bool = true,
    /// The marker line as written, for error messages.
    decl_line: ?[]const u8 = null,
};

/// Resolves a test's own `// build-gate: a, b` line by reading its source.
///
/// No marker means ungated, and that default fails safe: a gate exists
/// because a gated test @imports a module that only exists when its feature
/// does, so FORGETTING a marker becomes a compile error naming the missing
/// import, not a silently skipped test. An unknown feature NAME is fatal, so a
/// typo cannot read as "no gate at all".
fn readTestGate(b: *std.Build, path: []const u8, flags: []const FeatureFlag) !TestGate {
    var scan = try SourceScanner.open(b, path);
    defer scan.close();
    const marker = "// build-gate:";
    var out: TestGate = .{};
    var lines = scan.lines();
    while (lines.next()) |t| {
        if (!std.mem.startsWith(u8, t, marker)) continue;
        out.decl_line = t;
        out.on = true;
        var names = std.mem.tokenizeAny(u8, t[marker.len..], " ,\t");
        while (names.next()) |name| {
            var found = false;
            for (flags) |f| {
                if (std.mem.eql(u8, f.name, name)) {
                    found = true;
                    if (!f.on) out.on = false;
                }
            }
            if (!found) {
                std.debug.print("build: {s} declares build-gate feature '{s}', which is not a known feature name", .{ path, name });
                return error.UnknownBuildGateFeature;
            }
        }
        return out;
    }
    return out;
}

/// Input to `buildPluginTemplateCheck`: one dev/plugin-template file to
/// compile against the real modules, the import name to expose it under in
/// the generated wrapper, and whether the current tree provides its
/// dependencies (`present`; a skipped entry is left out of the wrapper
/// entirely).
const PluginTemplateSpec = struct {
    path: []const u8,
    import: []const u8,
    /// The template's registry export: the decl the generated
    /// wrapper references to force container and contract-binding
    /// analysis. `module` for the whole-surface templates
    /// (segment, layout, provider); the package's binding name
    /// (`sub`/`addon`) for the sub-addon templates, whose
    /// self-declaration is what build.zig's sub-registry
    /// generation keys on.
    decl: []const u8 = "module",
    present: bool,
};

/// Compiles every `dev/plugin-template/` file against the REAL discovered
/// modules (cross-wired exactly like an in-tree module, shared artefacts
/// included) and registers a `check-plugin-template` step, so contract drift
/// self-fails on `zig build check`. Compile-only: the wrapper test binary is
/// built, never run. Importing each template and referencing its registry
/// export (`module`, or the package's `sub`/`addon` binding for the
/// sub-addon templates) forces container analysis and contract-binding
/// type-checking — an import that no longer resolves, or a hook bound to a
/// stale signature or a deleted/renamed field, becomes a compile error here.
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
        finalizeModuleLinked(mod, optimize, has_usr); // libc for @cImport in imported core modules
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
        try src.print(b.allocator, "    _ = @import(\"{s}\").{s};\n", .{ spec.import, spec.decl });
    }
    try src.appendSlice(b.allocator, "}\n");

    const wrapper = makeGeneratedModule(b, target, optimize, "plugin_templates.zig", src.items, &.{});
    finalizeModuleLinked(wrapper, optimize, has_usr);
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
/// registration (`surfaces`), and every per-owner `modules` registry
/// (`<owner>_modules`). Shared by the root module and every discovered module
/// so there's exactly one place that knows what "every module gets this"
/// means. Generated registries are NOT passed through here (a module can't
/// receive its own import); they get their own imports in
/// `buildOwnerRegistries`.
fn injectShared(mod: *std.Build.Module, ctx: SharedBuildContext) void {
    mod.addImport("build_options", ctx.build_opts);
    mod.addImport("fallback_toml", ctx.fallback_toml);
    mod.addImport("surfaces", ctx.surfaces);
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

/// Applies release-mode stripping plus the memoized /usr include/library paths.
fn finalizeModule(mod: *std.Build.Module, optimize: std.builtin.OptimizeMode, has_usr: UsrDirs) void {
    stripIfRelease(mod, optimize);
    if (has_usr.lib) mod.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    if (has_usr.include) mod.addIncludePath(.{ .cwd_relative = "/usr/include" });
}

/// The standard "this module joins the libc-linked build graph" finalization:
/// declare libc (several modules call it directly — fallback's getenv,
/// window/floating's free, every @cImport — and edge-based wiring does not
/// supply it through a blanket test root) and apply `finalizeModule`.
/// Mirrors `injectShared` as the single call every module builder that needs
/// libc routes through, so the pair cannot drift apart.
fn finalizeModuleLinked(mod: *std.Build.Module, optimize: std.builtin.OptimizeMode, has_usr: UsrDirs) void {
    mod.link_libc = true;
    finalizeModule(mod, optimize, has_usr);
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

    /// Facts one source read extracts from a module file's `pub const module`
    /// declaration: whether the file binds the owner's module contract (owner-
    /// stem reservation) and which `contract.*` contract it binds (registry
    /// typing). Capture both in a single scan so the walk, the owner registry,
    /// and the contract derivation never re-read a file.
    const FileClass = struct {
        pub_module: bool = false,
        contract: ?[]const u8 = null,
    };

    /// Mutable state threaded through the entire discovery pass, grouped here
    /// so `discoverAll` and `registerModule` take only the arguments that
    /// actually vary per call.
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
        /// ONE source read per owner-tree file, split three ways: the walk
        /// uses it to reserve owner stems vs private siblings, `OwnerRegistry`
        /// re-uses it instead of re-scanning, and the contract derivation
        /// consumes the same classification. Every fact the build needs from a
        /// module's `pub const module` declaration is captured here.
        classified: std.StringHashMap(FileClass),

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
                .classified = std.StringHashMap(FileClass).init(b.allocator),
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
        /// modules dir all files count, in a deeper subdirectory the one
        /// sharing its directory's name (see addOwnerStem) plus any sibling
        /// that self-declares the owner's module binding (`pub const module`).
        /// `owner` is a b.allocator-backed slice (a basename duped from an
        /// ancestor `dir_path`), valid for the whole build.
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
                            const is_core = in_modules_root or
                                std.mem.eql(u8, std.fs.path.stem(entry.name), std.fs.path.basename(dir_path));
                            // Classify ONCE per file (reservation + contract,
                            // see FileClass); the walk's owner-vs-sibling
                            // decision and every later reader share the result.
                            try ctx.ensureClassified(rel_path);
                            const fc = ctx.classified.get(rel_path).?;
                            if (is_core or fc.pub_module) {
                                try ctx.addOwnerStem(o, std.fs.path.stem(entry.name));
                            } else {
                                // A private sibling of a dir-named package
                                // (systatus/{cpu,ram,...}.zig beside
                                // systatus.zig): parked under the package stem
                                // for its generated `<package>_subs` registry
                                // rather than becoming an owner stem. A sibling
                                // that SELF-DECLARES the owner's module binding
                                // is an owner stem instead (layout/variants
                                // grouped under src/bar/modules/layout/): the
                                // content check keeps grouping from orphaning a
                                // full segment into a sub registry nothing reads.
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

        /// Idempotent per-file classification (see `FileClass`): reads and
        /// scans `rel_path` once, memoizes the result, and errors loudly on a
        /// `pub const module` in an unrecognized spelling. Every owner-tree
        /// file the walk classifies is reused by `OwnerRegistry` and the
        /// contract derivation instead of being re-read.
        fn ensureClassified(ctx: *DiscoveryContext, rel_path: []const u8) !void {
            const b = ctx.b;
            const gop = try ctx.classified.getOrPut(try b.allocator.dupe(u8, rel_path));
            if (!gop.found_existing) gop.value_ptr.* = try classifyFile(b, rel_path);
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
        /// unsorted; `boundSubStems` sorts the bound subset that feeds the
        /// registry generator.
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
    /// from `injectShared` (build_options, fallback_toml, surfaces,
    /// `<owner>_modules`) — are skipped: they either need no wiring or are
    /// already present in the module's import_table.
    ///
    /// Only declared edges are wired, which is what keeps the compile CACHE
    /// proportional to real dependencies; the rationale lives with `wireAll`.
    fn importEdgesOf(
        b: *std.Build,
        rel_path: []const u8,
        modules: *std.StringHashMap(*std.Build.Module),
        out: *std.ArrayListUnmanaged([]const u8),
    ) !void {
        var scan = try SourceScanner.open(b, rel_path);
        defer scan.close();
        const src = scan.src;

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
    /// the pure vocabulary (src/core/pure/) and their own neighborhood.
    ///
    /// This is a DIRECT-edge (1-hop) guard: it rejects a pure layer's own
    /// import of a hub module — the shape of the config -> xkbcommon -> core
    /// -> config cycle — and catches regressions of that shape. It does not
    /// prove the module graph acyclic in general. Known exception: `keymap`,
    /// the config-facing keysym-name parser, lives in the input layer and is
    /// scanned as a hub edge; `pureLayerAllows` sanctions it explicitly
    /// because it is connection-free (no X connection, no xkb_state, no
    /// extension setup), so that directory-level config⇄input dependency
    /// passes the one-hop check without handing config any live-device
    /// wiring.
    ///
    /// This check is the IMPORT-EDGE guard only. The complementary body/
    /// reference sweep (any bare `xcb` token in the model vocabulary, tiling,
    /// and config, comments stripped) lives in check-layers.sh Rule 3 — an
    /// import of an xcb-using module passes here yet still lets `xcb` reach a
    /// pure file by re-export, so Rule 3 -- not this function -- is the sole
    /// guard on pure-layer xcb BODIES.
    fn assertPureLayerImports(
        name: []const u8,
        rel_path: []const u8,
        edges: []const []const u8,
        source_paths: *const std.StringHashMap([]const u8),
    ) !void {
        // The model vocabulary is the one pure root: core/model.zig (the
        // public facade) plus the Rect/Margins values that state holds
        // (core/architecture/domain.zig, private to the facade). `satI16`
        // also serves the pure tiling layer, which is why the coordinate
        // helpers cannot live on the x11 side. The src/core/pure/ shelf
        // (bounded, idmap) and src/core/display/ (scaling) are xcb-free by
        // construction. The architecture/ contract vocabulary
        // (contract_dispatch.zig, tiling_contract.zig) keeps xcb out as well
        // -- the concrete key-press struct and the Surfaces hook set live
        // with their binding site in hub-wired bar.zig -- so those files are
        // pure vocabulary and pass this scan like any other pure module.
        //
        // Documented carve-out: `src/config/reload.zig` is the reload
        // ORCHESTRATION root (load/validate/swap config, then rebuild the hub
        // subsystems), so it must import hub wiring -- keybinds, window,
        // admission, surfaces -- by design; it is exempt like a hub file.
        // check-layers.sh Rule 3 still sweeps its body for xcb tokens (it has
        // none: the rebuild reaches the wire only through other modules' APIs).
        if (std.mem.endsWith(u8, rel_path, "src/config/reload.zig")) return;
        // Same carve-out for `src/config/model_config.zig`, the reload/boot
        // SEEDING root: it stamps config into the model through the pipeline +
        // tiling-seam APIs, so its core imports are the orchestration design,
        // not layer leakage. Rule 3 still sweeps it for xcb tokens (none).
        if (std.mem.endsWith(u8, rel_path, "src/config/model_config.zig")) return;
        const layer = if (std.mem.endsWith(u8, rel_path, "src/core/architecture/domain.zig") or
            std.mem.endsWith(u8, rel_path, "src/core/model.zig"))
            "model"
        else if (std.mem.startsWith(u8, rel_path, "src/tiling/"))
            "tiling"
        else if (std.mem.startsWith(u8, rel_path, "src/config/"))
            "config"
        else
            return;

        for (edges) |dep| {
            if (!pureLayerAllows(layer, dep, source_paths)) {
                std.debug.print(
                    "Error: layer guard: pure-{s} module '{s}' imports hub module '{s}'. The pure layers may only import the shared utility shelf, `model`, and their own layer; see assertPureLayerImports in build.zig.\n",
                    .{ layer, name, dep },
                );
                return error.LayerGuardViolation;
            }
        }
    }

    /// The allowed-import policy behind `assertPureLayerImports`. The pure
    /// shelf — src/core/pure/ (bounded, idmap), src/core/display/scaling.zig,
    /// and the log/masks leaves — is xcb-free by construction and safe for
    /// every layer; the state facade (`model`, which re-exports the private
    /// vocabulary `domain`) is the shared data model AND the geometry
    /// vocabulary (Rect/Margins) that the state holds. A pure layer's OWN
    /// siblings are derived from the discovery walk (`source_paths`) rather
    /// than hand-listed, so the guard cannot go stale as a layer gains or
    /// loses files. The per-layer extras are the pure neighborhoods each
    /// layer legitimately reaches outside its own directory: tiling's
    /// cross-engine vocabulary in `tiling_contract`; config's pure `keymap`
    /// bridge into input (keysym-name parsing; the module is connection-free,
    /// so config never learns a live-device input module). Anything else is
    /// hub wiring and belongs behind an interface, not an import.
    fn pureLayerAllows(
        layer: []const u8,
        dep: []const u8,
        source_paths: *const std.StringHashMap([]const u8),
    ) bool {
        const shelf = [_][]const u8{
            "log",   "masks",    "bounded", "idmap", "scaling",
            // The config-parse vocabulary every `*_config` fragment needs to
            // read TOML: the shared types, the parser/document, the knob
            // engine, and the color decoder. All xcb-free by construction, so
            // a pure fragment in src/tiling/ may reach them without touching
            // hub wiring.
            "types", "document", "parser",  "knob",  "color",
        };
        for (shelf) |m| if (std.mem.eql(u8, m, dep)) return true;
        // The generated config facade: injected into every module like the
        // registries, so it is never a discovered-module edge -- allowed here
        // so the pure config layer's `@import("composed")` cannot trip the
        // guard if edge-based wiring ever sees the name.
        if (std.mem.eql(u8, dep, "composed")) return true;
        if (std.mem.eql(u8, dep, "model") or
            std.mem.eql(u8, dep, "domain")) return true;
        if (std.mem.eql(u8, layer, "model")) return false;
        // Same-layer siblings: any discovered module whose own source path
        // lives under this layer's directory root.
        if (source_paths.get(dep)) |dep_path| {
            if (std.mem.eql(u8, layer, "tiling")) {
                if (std.mem.startsWith(u8, dep_path, "src/tiling/")) return true;
                if (std.mem.eql(u8, dep, "tiling_contract")) return true;
                // tiling_sections canonicalizes layout names through the
                // config-layer vocab module (which itself stays pure).
                if (std.mem.eql(u8, dep, "layout_names")) return true;
            }
            if (std.mem.eql(u8, layer, "config")) {
                if (std.mem.startsWith(u8, dep_path, "src/config/")) return true;
                if (std.mem.eql(u8, dep, "keymap")) return true;
            }
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
                try assertPureLayerImports(name, rel_path, edges.items, source_paths);
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
