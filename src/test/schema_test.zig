//! Schema-driven config tests: proof points for the comptime knob table in
//! schema.zig.
//!
//! Covers the four behaviors the refactor must preserve exactly:
//!   1. Table defaults are byte-equal to types.Config's field initializers
//!      (the anti-drift pin behind getDefaultConfig's synthesis).
//!   2. A config file with no keys yields those same defaults end-to-end,
//!      including the non-scalar seed data (layouts, icons, bar columns).
//!   3. Every alias spelling resolves identically ([tiling] flat names vs
//!      [tiling.layouts.master-stack]; [workspaces] vs
//!      [bar.modules.workspaces]; segment_spacing -> spacing; aesthetics).
//!   4. Warn-and-revert range semantics and the getRatio bare-`1`
//!      ambiguity rule behave as before.
//!
//! Scratch files live under /tmp/opencode (pre-approved temp area); each
//! test uses a unique name and cleans up after itself.

const std = @import("std");
const testing = std.testing;

const config = @import("config");
const parser = @import("parser");
const schema = @import("schema");
const types = @import("types");

const io = std.Options.debug_io;
const scratch_dir = "/tmp/opencode";

fn scratchPath(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/hana-schema-{s}.toml", .{ scratch_dir, name });
}

fn writeScratchFile(abs_path: []const u8, bytes: []const u8) !void {
    const f = try std.Io.Dir.createFileAbsolute(io, abs_path, .{});
    defer f.close(io);
    try f.writePositionalAll(io, bytes, 0);
}

fn cleanupScratch(abs_path: []const u8) void {
    std.Io.Dir.deleteFileAbsolute(io, abs_path) catch {};
}

/// Loads a TOML string through the full production pipeline
/// (parse -> buildConfigFromDoc), like a real config file would be.
fn loadToml(alloc: std.mem.Allocator, name: []const u8, content: []const u8) !types.Config {
    const path = try scratchPath(alloc, name);
    defer alloc.free(path);
    try writeScratchFile(path, content);
    defer cleanupScratch(path);
    return try config.loadConfig(alloc, path);
}

/// Asserts every knob of `cfg` equals its table default. The comparator is
/// itself driven by the knob table, so a new schema entry is covered the
/// moment it is declared.
fn expectAllDefaults(cfg: *const types.Config) !void {
    const proto: types.Config = .{};
    inline for (schema.knobs) |k| {
        if (!std.meta.eql(schema.value(cfg, k.target), schema.value(&proto, k.target))) {
            std.debug.print("knob '{s}' deviates from its types.Config default\n", .{k.target});
            return error.SchemaDefaultMismatch;
        }
    }
}

test "schema table defaults equal types.Config{} field initializers" {
    // The prototype carries types.zig's initializer values; applying the
    // table over it must not move a single scalar. This is the pin that
    // lets getDefaultConfig synthesize from the table alone.
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    schema.applyDefaults(&cfg);
    try expectAllDefaults(&cfg);
}

test "key-less config file loads pure table defaults end-to-end" {
    var cfg = try loadToml(testing.allocator, "defaults", "# nothing but a comment\n");
    defer cfg.deinit(testing.allocator);
    try expectAllDefaults(&cfg);

    // Non-scalar seed data from getDefaultConfig.
    try testing.expectEqual(@as(usize, 1), cfg.tiling.layouts.items.len);
    try testing.expectEqualStrings("master", cfg.tiling.layouts.items[0]);
    try testing.expectEqualStrings("master", cfg.tiling.layout);
    try testing.expectEqual(@as(usize, 9), cfg.bar.workspace_icons.items.len);
    try testing.expectEqualStrings("9", cfg.bar.workspace_icons.items[8]);
    try testing.expectEqual(@as(usize, 3), cfg.bar.layout.items.len);
    try testing.expectEqual(types.BarSegmentAnchor.left, cfg.bar.layout.items[0].position);
    try testing.expectEqualStrings("workspaces", cfg.bar.layout.items[0].segments.items[0]);
    try testing.expectEqual(types.BarSegmentAnchor.center, cfg.bar.layout.items[1].position);
    try testing.expectEqualStrings("title", cfg.bar.layout.items[1].segments.items[0]);
    try testing.expectEqual(types.BarSegmentAnchor.right, cfg.bar.layout.items[2].position);
    try testing.expectEqualStrings("clock", cfg.bar.layout.items[2].segments.items[0]);
}

// Alias parity: both spellings must land on identical configs.

fn expectConfigsEqual(a: *const types.Config, b: *const types.Config) !void {
    inline for (schema.knobs) |k| {
        if (!std.meta.eql(schema.value(a, k.target), schema.value(b, k.target))) {
            std.debug.print("knob '{s}' differs between alias spellings\n", .{k.target});
            return error.AliasParityBroken;
        }
    }
}

test "master trio: flat [tiling] names match dedicated section" {
    var flat = try loadToml(testing.allocator, "master-flat",
        \\[tiling]
        \\master_count = 3
        \\master_side = "right"
        \\master_width = 60%
        \\
    );
    defer flat.deinit(testing.allocator);
    // The bare [tiling] marker matters: like the old parseTiling early
    // return, the whole tiling family -- including the dedicated spellings
    // -- stays inert unless the [tiling] section itself exists.
    var dedicated = try loadToml(testing.allocator, "master-dedicated",
        \\[tiling]
        \\[tiling.layouts.master-stack]
        \\count = 3
        \\side = "right"
        \\width = 60%
        \\
    );
    defer dedicated.deinit(testing.allocator);

    try expectConfigsEqual(&flat, &dedicated);
    try testing.expectEqual(@as(u8, 3), dedicated.tiling.master_count);
    try testing.expectEqual(types.MasterSide.right, dedicated.tiling.master_side);
    try testing.expectEqual(parser.ScalableValue.percentage(60.0), dedicated.tiling.master_width);
}

test "[tiling.aesthetics] and flat [tiling] gap/border reads agree" {
    var flat = try loadToml(testing.allocator, "aesthetics-flat",
        \\[tiling]
        \\gap_width = 7
        \\border_width = 3
        \\border_focused = "#112233"
        \\border_unfocused = 0x445566
        \\
    );
    defer flat.deinit(testing.allocator);
    // [tiling.aesthetics] alone is inert (parseTiling's historical early
    // return); the marker section opens the family.
    var sub = try loadToml(testing.allocator, "aesthetics-sub",
        \\[tiling]
        \\[tiling.aesthetics]
        \\gap_width = 7
        \\border_width = 3
        \\border_focused = "#112233"
        \\border_unfocused = 0x445566
        \\
    );
    defer sub.deinit(testing.allocator);
    try expectConfigsEqual(&flat, &sub);
    try testing.expectEqual(parser.ScalableValue.absolute(7.0), sub.tiling.gap_width);
    try testing.expectEqual(@as(u32, 0x112233), sub.tiling.border_focused);

    // And without the [tiling] marker, the quartet is ignored outright --
    // pinned here because akai.toml ships exactly that shape today.
    var lone = try loadToml(testing.allocator, "aesthetics-lone",
        \\[tiling.aesthetics]
        \\gap_width = 7
        \\
    );
    defer lone.deinit(testing.allocator);
    try testing.expectEqual(parser.ScalableValue.absolute(10.0), lone.tiling.gap_width);
}

test "[bar.modules.workspaces] and [workspaces] agree on count/enabled" {
    var flat_ws = try loadToml(testing.allocator, "ws-flat",
        \\[workspaces]
        \\count = 5
        \\enabled = false
        \\
    );
    defer flat_ws.deinit(testing.allocator);
    var nested = try loadToml(testing.allocator, "ws-nested",
        \\[bar.modules.workspaces]
        \\count = 5
        \\enabled = false
        \\
    );
    defer nested.deinit(testing.allocator);
    try expectConfigsEqual(&flat_ws, &nested);
    try testing.expectEqual(@as(u8, 5), nested.workspaces.count);
    try testing.expect(!nested.workspaces.enabled);
}

test "segment_spacing feeds BarConfig.spacing; workspaces count pads icons" {
    var cfg = try loadToml(testing.allocator, "spacing-icons",
        \\[bar]
        \\segment_spacing = 20
        \\icons = ["x"]
        \\
        \\[bar.modules.workspaces]
        \\count = 4
        \\
    );
    defer cfg.deinit(testing.allocator);
    try testing.expectEqual(parser.ScalableValue.absolute(20.0), cfg.bar.spacing);
    try testing.expectEqual(@as(u8, 4), cfg.workspaces.count);
    // Icons padded to the workspace count after the explicit entry.
    try testing.expectEqual(@as(usize, 4), cfg.bar.workspace_icons.items.len);
}

test "fallback chains: title/drun colors follow their siblings" {
    // Regime 1: no [bar.colors] at all. The accent trio was UNCONDITIONALLY
    // assigned its fallback sibling; the drun trio were left untouched
    // (null), deferring to BarConfig's read-time fallbacks.
    var no_colors = try loadToml(testing.allocator, "chains-nocolors",
        \\[bar]
        \\accent_color = "#010203"
        \\bg = "#040506"
        \\fg = "#070809"
        \\
    );
    defer no_colors.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0x010203), no_colors.bar.title_accent_color);
    try testing.expectEqual(@as(u32, 0x040506), no_colors.bar.title_unfocused_accent);
    try testing.expectEqual(@as(u32, 0x010203), no_colors.bar.title_minimized_accent);
    try testing.expectEqual(@as(?u32, null), no_colors.bar.drun_bg);
    try testing.expectEqual(@as(?u32, null), no_colors.bar.drun_prompt_color);

    // Regime 2: [bar.colors] present with only `title`. The accent trio now
    // reads per-key (absent keys copy their sibling); the drun trio are also
    // assigned -- copying siblings when their own keys are absent, exactly
    // like the old `if (colors)` block.
    var with_title = try loadToml(testing.allocator, "chains-title",
        \\[bar]
        \\accent_color = "#010203"
        \\bg = "#040506"
        \\fg = "#070809"
        \\
        \\[bar.colors]
        \\title = "#0a0b0c"
        \\
    );
    defer with_title.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0x0a0b0c), with_title.bar.title_accent_color);
    try testing.expectEqual(@as(u32, 0x040506), with_title.bar.title_unfocused_accent);
    try testing.expectEqual(@as(u32, 0x010203), with_title.bar.title_minimized_accent);
    try testing.expectEqual(@as(?u32, 0x040506), with_title.bar.drun_bg);
    try testing.expectEqual(@as(?u32, 0x070809), with_title.bar.drun_fg);
    try testing.expectEqual(@as(?u32, 0x010203), with_title.bar.drun_prompt_color);
    try testing.expectEqual(@as(u32, 0x040506), with_title.bar.drunBg());
    try testing.expectEqual(@as(?u32, null), with_title.bar.indicator_color);
}

test "warn-and-revert: out-of-range scalars revert to defaults" {
    var cfg = try loadToml(testing.allocator, "revert",
        \\[bar]
        \\carousel_speed_px_s = 0
        \\font_size = -10%
        \\
        \\[tiling]
        \\[tiling.aesthetics]
        \\gap_width = -50
        \\
        \\[drag]
        \\snap_distance = -1
        \\
        \\[bar.modules.workspaces]
        \\count = 999
        \\
    );
    defer cfg.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 125), cfg.bar.carousel_speed_px_s);
    try testing.expectEqual(parser.ScalableValue.percentage(10.0), cfg.bar.font_size);
    try testing.expectEqual(parser.ScalableValue.absolute(10.0), cfg.tiling.gap_width);
    try testing.expectEqual(parser.ScalableValue.absolute(8.0), cfg.snap_distance);
    try testing.expectEqual(@as(u8, 9), cfg.workspaces.count);
}

test "bar.position parses exactly; unknown spellings keep .top" {
    var bottom = try loadToml(testing.allocator, "pos-bottom",
        \\[bar]
        \\position = "bottom"
        \\
    );
    defer bottom.deinit(testing.allocator);
    try testing.expectEqual(types.BarScreenPosition.bottom, bottom.bar.bar_position);

    // Exact-case enum: "TOP" is not recognized and silently keeps .top --
    // no warning, unlike indicator_location's ci+warn flavor.
    var shouty = try loadToml(testing.allocator, "pos-shouty",
        \\[bar]
        \\position = "TOP"
        \\
    );
    defer shouty.deinit(testing.allocator);
    try testing.expectEqual(types.BarScreenPosition.top, shouty.bar.bar_position);
}

test "getRatio: bare 1 means 1 percent (ambiguity rule)" {
    var cfg = try loadToml(testing.allocator, "ratio-one",
        \\[bar]
        \\transparency = 1
        \\indicator_padding = 40%
        \\
    );
    defer cfg.deinit(testing.allocator);
    try testing.expectEqual(@as(f32, 0.01), cfg.bar.transparency);
    try testing.expectEqual(@as(f32, 0.4), cfg.bar.indicator_padding);
}

test "validate accepts pixel master_width above the ratio ceiling" {
    // Negative cases (99% ratio, negative pixels) are pinned by the manual
    // spot-check against a live WM: the stock test runner fails ANY test
    // whose code path emits an err-level log, and validate()'s rejection
    // path is exactly such a log ("Invalid config: ... keeping old").
    var px = try loadToml(testing.allocator, "mw-px",
        \\[tiling]
        \\master_width = 600
        \\
    );
    defer px.deinit(testing.allocator);
    try config.validate(&px);
    try testing.expectEqual(parser.ScalableValue.absolute(600.0), px.tiling.master_width);
}
