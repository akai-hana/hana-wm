//! Config → model seeding (src/core/architecture/seed.zig): the two pure halves the
//! boot/reload wrapper composes, tested without a boot.
//!
//! `seedParamsFromConfig` is the only state-touching step — it reads
//! `core.getState().config` and the global pipeline model, both of which need
//! `core.init` (and therefore an X connection) — and it is nothing more than
//! `templateFrom` + `model.applyConfigReload` + `applyOverrides`. Every rule
//! worth pinning lives in those halves, which take an explicit
//! `*const types.TilingConfig` precisely so this file can.

// Declared here, next to the imports that make it necessary, rather than in a
// build.zig table that had to be kept in agreement with them by hand.
// build-gate: tiling

const std = @import("std");
const testing = std.testing;

const seed = @import("seed");
const model = @import("wm_state");
const helpers = @import("helpers");
const types = @import("types");
const tiling = @import("tiling");
const contract = @import("contract");

const alloc = testing.allocator;

/// Append a layout-cycle name the way the parser hands it over: an
/// allocator-owned string (TilingConfig.deinit frees every entry).
fn addLayout(cfg: *types.TilingConfig, name: []const u8) !void {
    try cfg.layouts.append(alloc, try alloc.dupe(u8, name));
}

test "templateFrom resolves the default layout and stamps the model defaults" {
    var cfg = types.TilingConfig{};
    defer cfg.deinit(alloc);

    const tpl = seed.templateFrom(&cfg);

    // Empty cycle -> defaultLayout() is canon "master", so the resolved kind
    // must NAME master. Only moduleName can tell that apart from the neutral
    // default index, which a plain kind==expected-kind check would accept.
    try testing.expectEqualStrings("master", tiling.moduleName(tpl.kind));
    try testing.expectEqual(@as(u8, 1), tpl.primary_count); // master_count default
    try testing.expectEqual(@as(u8, 0), tpl.variant_idx); // no variants map entry
    try testing.expectEqual(@as(f32, 0.5), tpl.primary_width); // runtime-only reset
    try testing.expectEqual(@as(f32, 0), tpl.secondary_balance);
}

test "templateFrom clamps master_count to the primary-column ceiling" {
    var cfg = types.TilingConfig{};
    defer cfg.deinit(alloc);
    // The grammar admits the whole u8 range for the global count; 255 would
    // otherwise reach compute's master_n as a 255-column primary pane.
    cfg.master_count = 255;

    const tpl = seed.templateFrom(&cfg);

    try testing.expectEqual(@as(u8, model.max_primary_count), tpl.primary_count);
}

test "templateFrom falls back to the neutral default for an unresolvable layout" {
    var cfg = types.TilingConfig{};
    defer cfg.deinit(alloc);
    try addLayout(&cfg, "no-such-layout");

    const tpl = seed.templateFrom(&cfg);

    // The warn is silenced in test binaries; the fallback kind is the pin.
    try testing.expectEqual(contract.default_kind, tpl.kind);
}

test "templateFrom reads the per-layout variants map" {
    var cfg = types.TilingConfig{};
    defer cfg.deinit(alloc);
    try addLayout(&cfg, "master");
    // Key and value are both heap-duped by the parser (deinit frees both).
    try cfg.variants.put(alloc, try alloc.dupe(u8, "master"), try alloc.dupe(u8, "fifo"));

    const tpl = seed.templateFrom(&cfg);

    // master's variant table is [lifo, fifo]; "fifo" is slot 1.
    try testing.expectEqual(@as(u8, 1), tpl.variant_idx);
}

test "templateFrom ignores an unknown variants value-string" {
    var cfg = types.TilingConfig{};
    defer cfg.deinit(alloc);
    try addLayout(&cfg, "master");
    try cfg.variants.put(alloc, try alloc.dupe(u8, "master"), try alloc.dupe(u8, "bogus"));

    const tpl = seed.templateFrom(&cfg);

    // variant_parse returns null for an unmatched name -> warn and slot 0.
    try testing.expectEqual(@as(u8, 0), tpl.variant_idx);
}

test "applyOverrides applies last-wins layout/count overrides on top of the template" {
    var cfg = types.TilingConfig{};
    defer cfg.deinit(alloc);
    try addLayout(&cfg, "master");
    try addLayout(&cfg, "grid");

    // ws0: in-range layout override.
    try cfg.workspace_layout_overrides.append(alloc, .{
        .workspace_idx = .{ .index = 0 },
        .layout_idx = 1,
        .variant = null,
    });
    // ws1: out-of-range layout override whose variant string still applies to
    // whichever kind ends up active.
    try cfg.workspace_layout_overrides.append(alloc, .{
        .workspace_idx = .{ .index = 1 },
        .layout_idx = 99,
        .variant = try alloc.dupe(u8, "fifo"),
    });
    // ws2: two entries — the LAST one (out of range) wins, discarding the
    // in-range grid entry ahead of it.
    try cfg.workspace_layout_overrides.append(alloc, .{
        .workspace_idx = .{ .index = 2 },
        .layout_idx = 1,
        .variant = null,
    });
    try cfg.workspace_layout_overrides.append(alloc, .{
        .workspace_idx = .{ .index = 2 },
        .layout_idx = 99,
        .variant = null,
    });
    // ws3: a count past the column ceiling; ws4: a count of 0 (the grammar
    // admits it), both clamped to the model's invariant [1, max].
    try cfg.workspace_master_count_overrides.append(alloc, .{
        .workspace_idx = .{ .index = 3 },
        .count = 50,
    });
    try cfg.workspace_master_count_overrides.append(alloc, .{
        .workspace_idx = .{ .index = 4 },
        .count = 0,
    });

    // The production order: stamp the template everywhere, then re-stamp the
    // overrides on top of it.
    var m = helpers.makeModel();
    const tpl = seed.templateFrom(&cfg);
    model.applyConfigReload(&m, tpl);
    seed.applyOverrides(&m, &cfg, tpl.kind);

    // ws0: the in-range override replaces the default kind.
    try testing.expectEqualStrings("grid", tiling.moduleName(m.ws[0].params.kind));
    try testing.expectEqual(tpl.primary_count, m.ws[0].params.primary_count);

    // ws1: layout_idx 99 fell back to the default kind, but the override's
    // variant string applied to that kind anyway.
    try testing.expectEqual(tpl.kind, m.ws[1].params.kind);
    try testing.expectEqual(@as(u8, 1), m.ws[1].params.variant_idx); // master's "fifo"

    // ws2: last-wins — the out-of-range entry beat the earlier grid entry.
    try testing.expectEqual(tpl.kind, m.ws[2].params.kind);
    try testing.expectEqual(tpl.variant_idx, m.ws[2].params.variant_idx);

    // ws3/ws4: counts clamped into the model's invariant.
    try testing.expectEqual(@as(u8, model.max_primary_count), m.ws[3].params.primary_count);
    try testing.expectEqual(@as(u8, 1), m.ws[4].params.primary_count);

    // ws5: no override at all — still exactly the template.
    try testing.expectEqual(tpl.kind, m.ws[5].params.kind);
    try testing.expectEqual(tpl.variant_idx, m.ws[5].params.variant_idx);
    try testing.expectEqual(tpl.primary_count, m.ws[5].params.primary_count);
}
