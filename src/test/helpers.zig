const std = @import("std");
const model = @import("model");
const build_options = @import("build_options");

const time = @import("time");
const reconcile = @import("reconcile");
const sinkmod = @import("sink");
const test_sink = @import("test_sink");
/// Standard 800x600 test geometry (screen == workarea), shared by the sync
/// and tiling fixtures so no caller threads it through every init.
pub const std_wa: model.Rect = .{ .x = 0, .y = 0, .width = 800, .height = 600 };

/// Deterministically re-arms the process-global module stores (minimize,
/// fullscreen) that back the model transitions, so a test's first assertions
/// never depend on which earlier tests left records behind ("pass in any
/// order"). Both modules' init()/deinit() are idempotent resets (they
/// only clear their static stores), so calling this redundantly is harmless.
/// No-ops for modules absent from this build.
fn testReset() void {
    if (build_options.has_minimize) {
        @import("minimize").deinit();
        @import("minimize").init() catch unreachable;
    }
    if (build_options.has_fullscreen) {
        @import("fullscreen").deinit();
        @import("fullscreen").init() catch unreachable;
    }
    // Floating's drag state was never re-armed. It is a process-global
    // like the other two, and a left-active drag is not a cosmetic leak:
    // `startDrag` early-returns while `g_state.drag.active`, so one test that
    // did not end its drag silently disables dragging for every test after it.
    if (build_options.has_floating) {
        @import("floating").resetState();
    }
}

/// The ONE fixture entry: a fresh model on deterministically re-armed
/// process-global module stores.
///
/// There used to be two entry points with different guarantees -- `makeModel`
/// (bare) and `setUpModel` (reset first) -- and nothing in the type system said
/// which one a given test needed. Worse, `model_test` had locally aliased
/// `const makeModel = helpers.setUpModel`, so a reader scanning that file saw
/// `makeModel()` and reasonably assumed no reset happened. Reset is now the
/// default, so the bare path is the one you must ask for by name.
pub fn makeModel() model.Model {
    testReset();
    return .{};
}

/// A fresh model with the module stores left ALONE.
///
/// Only for the latency files, and the reason is measurement hygiene rather
/// than correctness: `testReset` frees and re-allocates the module stores, and
/// doing that between bench iterations churns the allocator and the cache
/// lines the next timed region is about to read, which is exactly the noise a
/// latency benchmark exists to avoid. Correctness tests must use `makeModel`.
pub fn makeBareModel() model.Model {
    return .{};
}

pub fn regCur(m: *model.Model, win: model.WindowId) void {
    model.register(m, win, null) catch unreachable;
}

/// Shared tiled-order expectation: `ws`'s ordered ids equal `expected`
/// exactly. The one copy across the model/fullscreen/minimize fixtures.
pub fn expectOrder(m: *const model.Model, ws: model.WSId, expected: []const model.WindowId) !void {
    try std.testing.expectEqualSlices(model.WindowId, expected, m.ws[ws.index].tiled_order.constSlice());
}

/// Floating-anchor window, the shape most store.put fixtures use.
pub fn addFloating(m: *model.Model, win: model.WindowId, r: model.Rect) !void {
    _ = try m.store.put(win, .{
        .mask = model.bit(model.WSId.fromIndex(0)),
        .anchor = .{ .floating = r },
    });
}

/// Registers a contiguous window-id run starting at `base` and returns the
/// ids for fixtures that need them.
pub fn registerRange(m: *model.Model, comptime n: usize, base: u32) [n]model.WindowId {
    var wins: [n]model.WindowId = undefined;
    for (&wins, 0..) |*w, i| {
        w.* = @intCast(base + @as(u32, @intCast(i)));
        regCur(m, w.*);
    }
    return wins;
}

pub fn colorOfFocused(win: model.WindowId, m: *const model.Model) u32 {
    return if (m.focused == win) 1 else 0;
}

/// Shared golden-sequence border-pixel convention: the sync and tracking
/// fixtures assert these exact focused/unfocused values, so they live here
/// as the single source instead of a per-file duplicate.
pub const focused_pixel: u32 = 100;
pub const unfocused_pixel: u32 = 200;

/// Configured border width the sync fixture sends on the wire (cfg_bw).
pub const cfg_bw: u16 = 2;

/// Golden-sequence border-color callback: bright border when focused, dim
/// otherwise. Shared by the sync/tracking fixtures (latency benches use the
/// cheaper colorOfFocused instead).
pub fn testColor(win: model.WindowId, m: *const model.Model) u32 {
    return if (m.focused == win) focused_pixel else unfocused_pixel;
}

pub fn makeCtx(
    sink: sinkmod.Sink,
    color_of: *const fn (model.WindowId, *const model.Model) u32,
    screen: model.Rect,
) reconcile.Ctx {
    return .{
        .sink = sink,
        .screen = screen,
        .workarea = screen,
        .color_of = color_of,
        .env = std_env,
    };
}

/// Warms the sync ledger with one steady-state reconcile, then times `iterations`
/// reconciles and returns nanoseconds per reconcile. Shared by the latency
/// benchmarks (the identical warm+bench pattern in the latency tests).
pub fn benchReconcile(m: *model.Model, iterations: usize) f64 {
    var warm = test_sink.TestSink(.category){};
    var warm_ctx = makeCtx(warm.sink(), colorOfFocused, std_wa);
    reconcile.run(m, &warm_ctx, .{});
    var bench = test_sink.TestSink(.category){};
    var bench_ctx = makeCtx(bench.sink(), colorOfFocused, std_wa);
    const t0 = time.monotonicNs();
    for (0..iterations) |_| reconcile.run(m, &bench_ctx, .{});
    return @as(f64, @floatFromInt(time.monotonicNs() - t0)) / @as(f64, @floatFromInt(iterations));
}

/// Standard test margin/min_dim tuning shared by the sync/tiling fixtures.
pub const std_env: @FieldType(reconcile.Ctx, "env") = .{
    .margins = .{ .gap = 8, .border = 2 },
    .min_dim = 50,
};

/// Canonical config-order layout cycle used by the model, tiling, and window
/// fixtures. Single source of truth so the test layouts list can't drift from
/// the config's accepted set (src/config/config.zig canonical layout names).
pub const std_layout_names = [_][]const u8{ "master", "monocle", "grid", "fibonacci", "leaf", "scroll" };

// --- bench timings go to a FILE, not to stderr ---

/// Appends one bench timing line to `.zig-cache/bench/timings.txt`.
///
/// Why a file and not `std.debug.print`: the Zig test protocol treats any
/// stderr output as a failed command, so the printed numbers made
/// `zig build test -Dbench=true` -- the only way to compile bench mode -- exit
/// non-zero on a fully passing suite. The documented invocation was therefore
/// guaranteed to report failure, and the two bench-only `std.debug.print`
/// sites had in fact gone stale enough to no longer compile (they read fields
/// the test sink does not have, and one referenced a `sink` that was not in
/// scope), which is exactly what happens to a code path nothing can run.
///
/// Writing here instead keeps the numbers, keeps the exit green, and makes the
/// output land somewhere a reader looks for it. Best-effort by design: a
/// timing that cannot be recorded must not fail a test, so every error here is
/// swallowed, exactly as the `note`/`flush` instrumentation is.
/// The one open handle for the timings file, opened on first use.
///
/// It has to be ONE handle, not one per call: `createFile` has no
/// append mode, so every fresh handle starts writing at offset 0 and each
/// record overwrote the head of the last one -- which showed up as timings
/// truncated to their own tails ("...=130 (configure=50,map=40)" with the
/// label and the numbers before it gone). Holding the handle for the run makes
/// the position advance naturally, and the test runner executes a binary's
/// tests sequentially, so there is no concurrent writer.
///
/// The handle is intentionally never closed: this is a short-lived test
/// process, and a close would need a teardown hook the test protocol does not
/// offer. One fd at process exit is not worth a shutdown path.
var bench_file: ?std.Io.File = null;

pub fn benchLog(comptime fmt: []const u8, args: anytype) void {
    const io = std.testing.io;
    if (bench_file == null) {
        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(io, ".zig-cache/bench") catch return;
        bench_file = cwd.createFile(io, ".zig-cache/bench/timings.txt", .{
            .truncate = false,
            .permissions = @enumFromInt(0o644),
        }) catch return;
        // createFile leaves the shared handle positioned at START OF FILE, so
        // every new process run wrote from offset 0 and clobbered the tail of
        // the previous one. Advance to EOF so this process appends after it.
        // std.os.linux wraps no lseek at 0.16, so we reach for it through the
        // fused built-in end endpoints; wrap the syscall for plain
        // portability to our Linux-only test harness.
        if (@import("builtin").os.tag == .linux) {
            _ = std.os.linux.lseek(bench_file.?.handle, 0, std.os.linux.SEEK.END);
        }
    }
    // Append a newline only if the caller's format does not already end in
    // one -- the bench formats all do, and adding another left a blank line
    // between every record.
    var buf: [512]u8 = undefined;
    const with_nl = comptime if (std.mem.endsWith(u8, fmt, "\n")) fmt else fmt ++ "\n";
    const line = std.fmt.bufPrint(&buf, with_nl, args) catch return;
    bench_file.?.writeStreamingAll(io, line) catch return;
}
