//! Fuzz entry points (P1-24), manual only -- no CI job.
//!
//! Each test hands one production target to `std.testing.fuzz` with a seed
//! corpus. In a normal (non-fuzz) build the runner replays the corpus plus the
//! empty input once per run, so CI always exercises the seeds; the mutation
//! loop is opt-in:
//!
//!   dev/scripts/xtest.sh zig build test -Dtest-filter=fuzz_test --fuzz=100000
//!
//! (the xtest wrapper because a bare `zig build test` on a live session steals
//! the display; --fuzz=<N> bounds the run, plain --fuzz runs forever).
//!
// build-gate: tiling

const std = @import("std");
const testing = std.testing;
const Smith = testing.Smith;

const model = @import("model");
const tiling = @import("tiling");
const contract = @import("tiling_contract");
const parser = @import("parser");
const composed = @import("composed");

// The invariant checker and its fixture are shared with the tiling sweep
// (one spelling of the five properties; importing a test module does not
// pull its test decls into this binary).
const tiling_test = @import("tiling_test");
const Fixture = tiling_test.Fixture;

/// Byte weights for config-shaped inputs: structure (printable ASCII) heavily
/// favored, control bytes and NULs still reachable, high bytes present so the
/// lexer meets them.
const config_byte_weights = [_]Smith.Weight{
    .rangeAtMost(u8, 0x00, 0x1f, 1),
    .rangeAtMost(u8, 0x20, 0x7e, 8),
    .rangeAtMost(u8, 0x7f, 0xff, 1),
};

/// parse -> composed.parse, the production chain (config.zig buildConfigFromDoc)
/// down to the knob layer. A rejection at either stage is a valid outcome;
/// only OOM propagates (a real test failure), and a success must deinit the
/// owned Config so the leak detector sees it.
fn fuzzConfigParse(_: void, smith: *Smith) !void {
    @disableInstrumentation();
    var buf: [4096]u8 = undefined;
    const len = smith.sliceWeightedBytes(&buf, &config_byte_weights);
    const input = buf[0..len];

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = parser.parse(arena.allocator(), input, "<fuzz>") catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    if (doc.had_errors) return;
    var cfg = composed.parse(testing.allocator, &doc) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    cfg.deinit(testing.allocator);
}

test "fuzz config parse" {
    // Seed corpus (committed here, per P1-24): rejected constructs, deep
    // arrays, the 1 MiB boundary, CRLF, BOM, NULs, [[x]], cyclic palette
    // refs, plus one valid document so the success path replays too.
    // The deep array and the 1 MiB slice are built per run; everything else
    // is static.
    const deep = try testing.allocator.alloc(u8, 64 * 1024);
    defer testing.allocator.free(deep);
    const deep_slice = deep: {
        var f = std.Io.Writer.fixed(deep);
        try f.writeAll("[bar]\nfonts = [");
        var i: usize = 0;
        while (i < 4000) : (i += 1) {
            if (i != 0) try f.writeAll(", ");
            try f.print("\"m{d}\"", .{i});
        }
        try f.writeAll("]\n");
        break :deep f.buffered();
    };
    const big = try testing.allocator.alloc(u8, 1024 * 1024);
    defer testing.allocator.free(big);
    @memset(big, 'a');

    return testing.fuzz({}, fuzzConfigParse, .{
        .corpus = &.{
            "[tiling]\nlayout = \"master\"\ngap_width = 12\n",
            "[core]\nfoo = { a = 1 }\n",
            "a.b = 1\n",
            "[[x]]\nfoo = 1\n",
            "[bar]\nposition = 2024-01-01\n",
            "[bar]\nname = \"\"\"multi\nline\"\"\"\n",
            "[tiling]\r\nlayout = \"master\"\r\n",
            "\xEF\xBB\xBF[tiling]\nlayout = \"leaf\"\n",
            "[tiling]\nlayout = \"mas\x00ter\"\n",
            "[bar]\nprimary_color = text_color\ntext_color = primary_color\n",
            "[tiling]\nlayout = \"grid\"\n[binds]\nMod+{1-9} = \"workspace\"\n",
            deep_slice,
            big,
        },
    });
}

/// Scenario knobs from the input, then every registered layout over the
/// five placement invariants (count/order/bounds/positive-area/non-overlap).
/// The workarea deliberately includes negative origins and zero extents, and
/// the params axes run out of their config-clamped band (finite only: the
/// config path cannot produce NaN).
fn fuzzTilingInvariants(_: void, smith: *Smith) !void {
    @disableInstrumentation();
    const n: usize = smith.valueRangeAtMost(u8, 0, 16);
    const wa: model.Rect = .{
        .x = smith.valueRangeAtMost(i16, -8, 40),
        .y = smith.valueRangeAtMost(i16, -8, 40),
        .width = smith.valueRangeAtMost(u16, 0, 300),
        .height = smith.valueRangeAtMost(u16, 0, 300),
    };
    var wins: [16]model.WindowId = undefined;
    for (&wins, 0..) |*w, i| w.* = @intCast(200 + i);

    var fx: Fixture = undefined;
    try fx.initAt(wins[0..n], wa);
    fx.m.ws[0].params.primary_count = smith.valueRangeAtMost(u8, 1, 12);
    // Floats have no continuous Smith range; quantize through an integer so
    // the sweep covers out-of-band-but-finite widths/balances.
    fx.m.ws[0].params.primary_width =
        @as(f32, @floatFromInt(smith.valueRangeAtMost(i16, -50, 150))) / 100.0;
    fx.m.ws[0].params.secondary_balance =
        @as(f32, @floatFromInt(smith.valueRangeAtMost(i16, -40, 40))) / 10.0;

    const env: contract.Env = .{
        .margins = .{
            .gap = smith.valueRangeAtMost(u16, 0, 12),
            .border = smith.valueRangeAtMost(u16, 0, 6),
        },
        .min_dim = smith.valueRangeAtMost(u16, 0, 60),
        .primary_on_right = smith.value(bool),
    };

    var v = fx.view();
    v.env = env;

    const kind: u8 = @intCast(smith.index(contract.tiling_mods.len));
    if (contract.tiling_mods[kind].compute == null) return;
    const vcount: usize = contract.tiling_mods[kind].variant_count;
    if (vcount != 0) fx.m.ws[0].params.variant_idx = @intCast(smith.index(vcount));

    // Rebuild the view after the variant mutation (params are a const handle
    // into the model; same reason the sweep re-inits per area).
    v = fx.view();
    v.env = env;

    var out = tiling_test.computeOf(kind, v);
    tiling_test.assertInvariants(&out, v, wa) catch |err| {
        std.debug.print("FUZZ-INVARIANT {s} n={d} wa=({d},{d} {d}x{d}) env=(gap={d},border={d},min={d},right={any}) params=(count={d},width={d},balance={d},variant={d}) err={s}\n", .{
            contract.tiling_mods[kind].name,     n,                               wa.x,
            wa.y,                                wa.width,                        wa.height,
            env.margins.gap,                     env.margins.border,              env.min_dim,
            env.primary_on_right,                fx.m.ws[0].params.primary_count, fx.m.ws[0].params.primary_width,
            fx.m.ws[0].params.secondary_balance, fx.m.ws[0].params.variant_idx,   @errorName(err),
        });
        std.debug.print("  rects:", .{});
        for (out.constSlice()) |p|
            std.debug.print(" {d}({d},{d} {d}x{d}{s})", .{
                p.win,         p.rect.x,
                p.rect.y,      p.rect.width,
                p.rect.height, if (p.visible) "" else " hidden",
            });
        std.debug.print("\n", .{});
        return err;
    };
}

test "fuzz tiling placement invariants" {
    return testing.fuzz({}, fuzzTilingInvariants, .{});
}
