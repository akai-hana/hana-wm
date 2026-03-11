//! Build configuration for Hana window manager
const std = @import("std");

/// Root source directory. Change this one constant to relocate the entire source tree.
const ROOT_DIR = "src/";

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize",
        "Set the optimization mode (Debug, ReleaseFast, ReleaseSafe, ReleaseSmall)")
        orelse .ReleaseFast;

    // Install prefix 
    // Try system-wide bin directories in order; fall back to ./bin/ if none are
    // writable or exist. The user can still override with -Dprefix=... as usual.
    if (b.install_prefix.len == 0 or std.mem.eql(u8, b.install_prefix, b.pathFromRoot("zig-out"))) {
        // System bin dirs are only writable as root.  For non-root builds skip
        // straight to the local fallback rather than probing dirs we can't use.
        const is_root = std.posix.getuid() == 0;
        var found = false;
        if (is_root) {
            const linux = std.os.linux;
            const candidates = [_][*:0]const u8{ "/usr/bin", "/usr/local/bin", "/bin" };
            for (candidates) |dir| {
                // faccessat with W_OK=2 checks the dir is writable.
                const rc = linux.faccessat(linux.AT.FDCWD, dir, 2, 0);
                if (linux.errno(rc) == .SUCCESS) {
                    b.install_prefix = std.mem.span(dir);
                    found = true;
                    break;
                }
            }
        }
        if (!found) {
            b.install_prefix = b.pathFromRoot("bin");
        }
    }

    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_debug_logging", optimize == .Debug);
    const fallback_toml = b.build_root.handle.readFileAlloc(
        b.graph.io, "config/fallback.toml", b.allocator, .limited(1024 * 1024),
    ) catch null;
    build_options.addOption(bool,       "has_fallback_toml", fallback_toml != null);
    build_options.addOption([]const u8, "fallback_toml",     fallback_toml orelse "");
    // Optional subsystem flags — false when the entry-point file is absent so
    // main.zig can guard @import("bar") / @import("input") at comptime.
    const has_bar   = fileExists(b, ROOT_DIR ++ "bar/bar.zig");
    const has_input = fileExists(b, ROOT_DIR ++ "input/input.zig");
    build_options.addOption(bool, "has_bar",   has_bar);
    build_options.addOption(bool, "has_input", has_input);

    const root_module = b.createModule(.{
        .root_source_file = b.path(ROOT_DIR ++ "core/main.zig"),
        .target    = target,
        .optimize  = optimize,
        .link_libc = true,
    });

    if (optimize != .Debug) {
        root_module.strip = true;
    }

    const exe = b.addExecutable(.{ .name = "hana", .root_module = root_module });

    var arena = std.heap.ArenaAllocator.init(b.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // name -> (module, absolute source path)
    var all_modules = std.StringHashMap(ModuleEntry).init(allocator);

    discoverModules(b, ROOT_DIR, target, optimize, allocator, &all_modules) catch |err| {
        std.debug.print("Fatal: failed to discover modules: {}\n", .{err});
        std.process.exit(1);
    };

    const Stub = struct { name: []const u8, src: []const u8, filename: []const u8 };
    const stubs = [_]Stub{
        .{ .name = "bar",   .src = bar_stub_src,   .filename = "bar_stub.zig"   },
        .{ .name = "input", .src = input_stub_src, .filename = "input_stub.zig" },
        .{ .name = "dpi",   .src = dpi_stub_src,   .filename = "dpi_stub.zig"   },
    };
    inline for (stubs) |stub| {
        if (!all_modules.contains(stub.name)) {
            const src = b.addWriteFiles().add(stub.filename, stub.src);
            all_modules.put(stub.name, .{
                .module = b.addModule(stub.name, .{
                    .root_source_file = src,
                    .target   = target,
                    .optimize = optimize,
                }),
                .source_path = "",
            }) catch @panic("OOM: stub registration");
        }
    }

    const build_options_module = build_options.createModule();

    const layout_flags_src = std.fmt.allocPrint(allocator,
        \\pub const has_master    = {};
        \\pub const has_monocle   = {};
        \\pub const has_grid      = {};
        \\pub const has_fibonacci = {};
        \\
    , .{
        all_modules.contains("master"),
        all_modules.contains("monocle"),
        all_modules.contains("grid"),
        all_modules.contains("fibonacci"),
    }) catch @panic("OOM");

    const layout_flags_module = b.createModule(.{
        .root_source_file = b.addWriteFiles().add("layout_flags.zig", layout_flags_src),
        .target   = target,
        .optimize = optimize,
    });

    // bar_flags: tells bar.zig which segment module files are present on disk.
    // When has_any_segment is false, BarFull is never analyzed by Zig's lazy
    // evaluator, so drawing.zig is never compiled and cairo/pango are not linked.
    const has_any_segment = all_modules.contains("tags")       or
                            all_modules.contains("layout")     or
                            all_modules.contains("variations") or
                            all_modules.contains("title")      or
                            all_modules.contains("clock")      or
                            all_modules.contains("status");

    const bar_flags_src = std.fmt.allocPrint(allocator,
        \\pub const has_tags       = {};
        \\pub const has_layout     = {};
        \\pub const has_variations = {};
        \\pub const has_title      = {};
        \\pub const has_clock      = {};
        \\pub const has_status     = {};
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
    root_module.addImport("layout_flags",  layout_flags_module);
    root_module.addImport("bar_flags",     bar_flags_module);

    // Wire each module based on what it actually @imports.
    wireModules(b, root_module, &all_modules, build_options_module, layout_flags_module, bar_flags_module, optimize, allocator);

    if (all_modules.get("defs")) |defs_entry| {
        var it = all_modules.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.source_path.len == 0)
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
    source_path: []const u8, // path relative to build root
};

fn wireModules(
    b:                    *std.Build,
    root:                 *std.Build.Module,
    all_modules:          *std.StringHashMap(ModuleEntry),
    build_options_module: *std.Build.Module,
    layout_flags_module:  *std.Build.Module,
    bar_flags_module:     *std.Build.Module,
    optimize:             std.builtin.OptimizeMode,
    allocator:            std.mem.Allocator,
) void {
    var iter = all_modules.iterator();
    while (iter.next()) |entry| {
        const mod = entry.value_ptr.module;

        if (optimize != .Debug) {
            mod.strip = true;
        }

        mod.addImport("build_options", build_options_module);
        mod.addImport("layout_flags",  layout_flags_module);
        mod.addImport("bar_flags",     bar_flags_module);

        // Read the source file and wire only the @imports that are known modules.
        const imports = findModuleImports(b, allocator, entry.value_ptr.source_path, all_modules);
        for (imports) |name| {
            const dep = all_modules.get(name) orelse continue;
            mod.addImport(name, dep.module);
        }

        // Expose every module on root so main.zig can import it.
        root.addImport(entry.key_ptr.*, mod);
    }
}

/// Reads `source_path` (relative to build root) and returns every @import("name")
/// where `name` is a key in `all_modules`. Slices point into arena-allocated
/// source bytes — safe because the arena outlives the entire build() call.
fn findModuleImports(
    b:           *std.Build,
    allocator:   std.mem.Allocator,
    source_path: []const u8,
    all_modules: *std.StringHashMap(ModuleEntry),
) []const []const u8 {
    const source = b.build_root.handle.readFileAlloc(
        b.graph.io, source_path, allocator, .limited(1024 * 1024),
    ) catch return &.{};
    // Do NOT free source — name slices below point into it.

    var results: std.ArrayList([]const u8) = .empty;
    const needle = "@import(\"";
    var pos: usize = 0;
    while (std.mem.indexOf(u8, source[pos..], needle)) |rel| {
        pos += rel + needle.len;
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

// Generated stub sources 

const bar_stub_src =
    \\const defs = @import("defs");
    \\const xcb  = defs.xcb;
    \\
    \\pub const BarAction = enum { toggle, hide_fullscreen, show_fullscreen };
    \\
    \\pub fn init(_: *defs.WM) error{BarDisabled}!void          { return error.BarDisabled; }
    \\pub fn deinit() void                                       {}
    \\pub fn reload(_: *defs.WM) void                           {}
    \\pub fn toggleBarPosition(_: *defs.WM) !void               {}
    \\pub fn getBarWindow() u32                                  { return 0; }
    \\pub fn isBarWindow(_: u32) bool                           { return false; }
    \\pub fn getBarHeight() u16                                  { return 0; }
    \\pub fn isBarInitialized() bool                            { return false; }
    \\pub fn hasClockSegment() bool                             { return false; }
    \\pub fn markDirty() void                                   {}
    \\pub fn redrawImmediate(_: *defs.WM) void                  {}
    \\pub fn raiseBar() void                                    {}
    \\pub fn isVisible() bool                                   { return false; }
    \\pub fn getGlobalVisibility() bool                         { return false; }
    \\pub fn setGlobalVisibility(_: bool) void                  {}
    \\pub fn setBarState(_: *defs.WM, _: BarAction) void        {}
    \\pub fn updateIfDirty(_: *defs.WM) !void                  {}
    \\pub fn checkClockUpdate() void                            {}
    \\pub fn pollTimeoutMs() i32                                { return -1; }
    \\pub fn updateTimerState() void                            {}
    \\pub fn handleExpose(_: *const xcb.xcb_expose_event_t, _: *defs.WM) void                 {}
    \\pub fn handlePropertyNotify(_: *const xcb.xcb_property_notify_event_t, _: *defs.WM) void {}
    \\pub fn monitorFocusedWindow(_: *defs.WM) void             {}
    \\pub fn handleButtonPress(_: *const xcb.xcb_button_press_event_t, _: *defs.WM) void      {}
    \\pub fn notifyFocusChange(_: *defs.WM, _: ?u32) void       {}
    \\
;

const input_stub_src =
    \\const defs = @import("defs");
    \\const xcb  = defs.xcb;
    \\
    \\pub fn setupGrabs(_: *xcb.xcb_connection_t, _: u32) void                          {}
    \\pub fn init(_: *defs.WM) !void                                                     {}
    \\pub fn deinit() void                                                                {}
    \\pub fn rebuildKeybindMap(_: *defs.WM) !void                                       {}
    \\pub fn handleKeyPress(_: *xcb.xcb_key_press_event_t, _: *defs.WM) void           {}
    \\pub fn handleButtonPress(_: *xcb.xcb_button_press_event_t, _: *defs.WM) void     {}
    \\pub fn handleButtonRelease(_: *xcb.xcb_button_release_event_t, _: *defs.WM) void {}
    \\pub fn handleMotionNotify(_: *xcb.xcb_motion_notify_event_t, _: *defs.WM) void   {}
    \\
;

const dpi_stub_src =
    \\const defs = @import("defs");
    \\const xcb  = defs.xcb;
    \\
    \\pub const DpiInfo = struct {
    \\    dpi:          f64,
    \\    scale_factor: f64,
    \\};
    \\
    \\pub fn detect(
    \\    _: *xcb.xcb_connection_t,
    \\    _: *xcb.xcb_screen_t,
    \\) error{}!DpiInfo {
    \\    return .{ .dpi = 96.0, .scale_factor = 1.0 };
    \\}
    \\
;

/// Returns true when `path` (relative to the build root) names a regular file.
/// Uses the same b.graph.io API as the rest of the build so behaviour is
/// consistent across platforms and Zig versions.
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
            // Gate optional subsystems: skip the entire subtree when the
            // subsystem's entry-point file is absent.  All other subdirectories
            // are always recursed into unconditionally.
            if (std.mem.eql(u8, entry.name, "bar") or
                std.mem.eql(u8, entry.name, "input"))
            {
                const gate_path = try std.fs.path.join(allocator,
                    &.{ dir_path, entry.name, entry.name });
                const gate_zig  = try std.mem.concat(allocator, u8, &.{ gate_path, ".zig" });
                if (!fileExists(b, gate_zig)) continue;
            }
            const subdir = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            try discoverModules(b, subdir, target, optimize, allocator, all_modules);
            continue;
        }

        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        if (std.mem.eql(u8, entry.name, "main.zig")) continue;

        const name = std.fs.path.stem(entry.name);
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
