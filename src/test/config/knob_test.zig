// build-gate: bar, tiling, workspaces, floating
//! Knob-driven config tests: proof points for the per-fragment comptime
//! knob tables (core_config, tiling_config, bar_config, workspaces_config,
//! floating_config) driven through knob.zig's generic engine.
//!
//! Covers the four behaviors these tests pin exactly:
//!   1. Every fragment's table defaults are byte-equal to its Config's
//!      field initializers (the anti-drift pin behind parse synthesis).
//!   2. A config file with no keys yields those same defaults end-to-end,
//!      including the non-scalar seed data (layouts, icons, bar columns).
//!   3. Every alias spelling resolves identically ([tiling] flat names vs
//!      [tiling.layouts.master-stack]; [workspaces] vs
//!      [bar.modules.workspaces]; per_segment_padding -> spacing).
//!   4. Warn-and-revert range semantics and both getRatio policies
//!      (legacy bare-integer percentages for indicator_padding; the
//!      strict no-bare-integers rule for transparency).
//!
//! Scratch files come from src/test/config/scratch.zig, built on per-call
//! `std.testing.tmpDir`; each test cleans up after itself.

const std = @import("std");
const testing = std.testing;

// The tests deliberately exercise warn-and-revert / layouts-cap
// diagnostics; src/core/debug/log.zig silences all std.log diagnostics in
// test binaries, so this stays quiet on success.
const config = @import("config");
const diagnostics = @import("diagnostics");
const knob = @import("knob");
const types = @import("types");
const composed = @import("composed");
const core_config = @import("core_config");
const tiling_config = @import("tiling_config");
const bar_config = @import("bar_config");
const workspaces_config = @import("workspaces_config");
const floating_config = @import("floating_config");
const scratch = @import("scratch");

const loadToml = scratch.loadToml;

/// Asserts every knob of one fragment's `cfg` equals its table default. The
/// comparator is itself driven by the fragment's knob table, so a new entry
/// is covered the moment it is declared.
fn expectFragmentDefaults(comptime CfgT: type, comptime knobs: []const knob.Knob, cfg: *const CfgT) !void {
    const proto: CfgT = .{};
    inline for (knobs) |k| {
        if (!std.meta.eql(knob.value(CfgT, cfg, k.target), knob.value(CfgT, &proto, k.target))) {
            std.debug.print("knob '{s}' deviates from its default\n", .{k.target});
            return error.SchemaDefaultMismatch;
        }
    }
}

fn expectAllDefaults(cfg: *const composed.Config) !void {
    try expectFragmentDefaults(types.CoreConfig, &core_config.knobs, &cfg.core);
    try expectFragmentDefaults(tiling_config.Config, &tiling_config.knobs, &cfg.tiling);
    try expectFragmentDefaults(bar_config.Config, &bar_config.knobs, &cfg.bar);
    try expectFragmentDefaults(workspaces_config.Config, &workspaces_config.knobs, &cfg.workspaces);
    try expectFragmentDefaults(floating_config.Config, &floating_config.knobs, &cfg.floating);
}

test "fragment Configs carry sensible field initializers" {
    const bar_proto: bar_config.Config = .{};
    try testing.expect(bar_proto.enabled);
    try testing.expectEqual(@as(u32, 0x222222), bar_proto.bg);
    try testing.expectEqual(@as(u32, 0x61AFEF), bar_proto.primary_color);
    try testing.expectEqual(bar_config.BarScreenPosition.top, bar_proto.bar_position);

    const ws_proto: workspaces_config.Config = .{};
    try testing.expectEqual(@as(u8, 9), ws_proto.count);

    const tiling_proto: tiling_config.Config = .{};
    try testing.expectEqual(tiling_config.MasterSide.left, tiling_proto.master_side);
    try testing.expectEqual(types.ScalableValue.percentage(50.0), tiling_proto.master_width);
}

test "key-less config file loads pure table defaults end-to-end" {
    var cfg = try loadToml(testing.allocator, "defaults", "# nothing but a comment\n");
    defer cfg.deinit(testing.allocator);
    try expectAllDefaults(&cfg);

    // Non-scalar seed data from getDefaultConfig.
    try testing.expectEqual(@as(usize, 1), cfg.tiling.layouts.items.len);
    try testing.expectEqualStrings("master", cfg.tiling.layouts.items[0]);
    try testing.expectEqualStrings("master", cfg.tiling.defaultLayout());
    try testing.expectEqual(@as(usize, 9), cfg.bar.workspace_icons.items.len);
    try testing.expectEqualStrings("9", cfg.bar.workspace_icons.items[8]);
    try testing.expectEqual(@as(usize, 3), cfg.bar.layout.items.len);
    try testing.expectEqual(bar_config.BarSegmentAnchor.left, cfg.bar.layout.items[0].position);
    try testing.expectEqualStrings("workspaces", cfg.bar.layout.items[0].segments.items[0]);
    try testing.expectEqual(bar_config.BarSegmentAnchor.center, cfg.bar.layout.items[1].position);
    try testing.expectEqualStrings("title", cfg.bar.layout.items[1].segments.items[0]);
    try testing.expectEqual(bar_config.BarSegmentAnchor.right, cfg.bar.layout.items[2].position);
    try testing.expectEqualStrings("clock", cfg.bar.layout.items[2].segments.items[0]);
}

// Alias parity: both spellings must land on identical configs.

fn expectFragmentEqual(comptime CfgT: type, comptime knobs: []const knob.Knob, a: *const CfgT, b: *const CfgT) !void {
    inline for (knobs) |k| {
        if (!std.meta.eql(knob.value(CfgT, a, k.target), knob.value(CfgT, b, k.target))) {
            std.debug.print("knob '{s}' differs between alias spellings\n", .{k.target});
            return error.AliasParityBroken;
        }
    }
}

fn expectConfigsEqual(a: *const composed.Config, b: *const composed.Config) !void {
    try expectFragmentEqual(types.CoreConfig, &core_config.knobs, &a.core, &b.core);
    try expectFragmentEqual(tiling_config.Config, &tiling_config.knobs, &a.tiling, &b.tiling);
    try expectFragmentEqual(bar_config.Config, &bar_config.knobs, &a.bar, &b.bar);
    try expectFragmentEqual(workspaces_config.Config, &workspaces_config.knobs, &a.workspaces, &b.workspaces);
    try expectFragmentEqual(floating_config.Config, &floating_config.knobs, &a.floating, &b.floating);
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
    // The bare [tiling] marker matters: the whole tiling family -- including
    // the dedicated spellings -- stays inert unless the [tiling] section
    // itself exists.
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
    try testing.expectEqual(tiling_config.MasterSide.right, dedicated.tiling.master_side);
    try testing.expectEqual(types.ScalableValue.percentage(60.0), dedicated.tiling.master_width);
}

test "[tiling] gap/border quartet reads" {
    var flat = try loadToml(testing.allocator, "aesthetics-flat",
        \\[tiling]
        \\gap_width = 7
        \\border_width = 3
        \\border_focused = "#112233"
        \\border_unfocused = 0x445566
        \\
    );
    defer flat.deinit(testing.allocator);
    try testing.expectEqual(types.ScalableValue.absolute(7.0), flat.tiling.gap_width);
    try testing.expectEqual(types.ScalableValue.absolute(3.0), flat.tiling.border_width);
    try testing.expectEqual(@as(u32, 0x112233), flat.tiling.border_focused);
    try testing.expectEqual(@as(u32, 0x445566), flat.tiling.border_unfocused);

    // A lone [tiling] (no functional keys at all) still feeds the
    // quartet -- this is exactly the shape akai.toml ships today.
    var lone = try loadToml(testing.allocator, "aesthetics-lone",
        \\[tiling]
        \\gap_width = 7
        \\
    );
    defer lone.deinit(testing.allocator);
    try testing.expectEqual(types.ScalableValue.absolute(7.0), lone.tiling.gap_width);
}

test "[bar.modules.workspaces] and [workspaces] agree on count" {
    var flat_ws = try loadToml(testing.allocator, "ws-flat",
        \\[workspaces]
        \\count = 5
        \\
    );
    defer flat_ws.deinit(testing.allocator);
    var nested = try loadToml(testing.allocator, "ws-nested",
        \\[bar.modules.workspaces]
        \\count = 5
        \\
    );
    defer nested.deinit(testing.allocator);
    try expectConfigsEqual(&flat_ws, &nested);
    try testing.expectEqual(@as(u8, 5), nested.workspaces.count);
}

test "per_segment_padding feeds BarConfig.spacing; workspaces count pads icons" {
    var cfg = try loadToml(testing.allocator, "spacing-icons",
        \\[bar]
        \\per_segment_padding = 20
        \\icons = ["x"]
        \\
        \\[bar.modules.workspaces]
        \\count = 4
        \\
    );
    defer cfg.deinit(testing.allocator);
    try testing.expectEqual(types.ScalableValue.absolute(20.0), cfg.bar.spacing);
    try testing.expectEqual(@as(u8, 4), cfg.workspaces.count);
    // Icons padded to the workspace count after the explicit entry.
    try testing.expectEqual(@as(usize, 4), cfg.bar.workspace_icons.items.len);
}

test "fallback chains: title/run colors follow their siblings" {
    // Regime 1: no [bar.properties] at all. The accent trio is UNCONDITIONALLY
    // assigned its fallback sibling (the palette canon: primary_color /
    // secondary_color / alternative_color); the run trio are left untouched (null),
    // deferring to BarConfig's read-time fallbacks.
    var no_colors = try loadToml(testing.allocator, "chains-nocolors",
        \\[bar]
        \\primary_color     = "#010203"
        \\secondary_color   = "#040506"
        \\alternative_color = "#050607"
        \\bg = "#0a0b0c"
        \\
    );
    defer no_colors.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0x010203), no_colors.bar.title_accent_color);
    try testing.expectEqual(@as(u32, 0x040506), no_colors.bar.title_unfocused_accent);
    try testing.expectEqual(@as(u32, 0x050607), no_colors.bar.title_minimized_accent);
    try testing.expectEqual(@as(?u32, null), no_colors.bar.run_bg);
    try testing.expectEqual(@as(?u32, null), no_colors.bar.run_prompt_color);
    try testing.expectEqual(@as(u32, 0x010203), no_colors.bar.runPromptColor());

    // Regime 2: [bar.properties] present with only `title`. The accent trio now
    // reads per-key (absent keys copy their sibling); the run trio are also
    // assigned -- copying siblings when their own keys are absent.
    var with_title = try loadToml(testing.allocator, "chains-title",
        \\[bar]
        \\primary_color     = "#010203"
        \\secondary_color   = "#040506"
        \\alternative_color = "#050607"
        \\bg = "#0a0b0c"
        \\fg = "#070809"
        \\
        \\[bar.properties]
        \\title = "#0a0b0c"
        \\
    );
    defer with_title.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0x0a0b0c), with_title.bar.title_accent_color);
    try testing.expectEqual(@as(u32, 0x040506), with_title.bar.title_unfocused_accent);
    try testing.expectEqual(@as(u32, 0x050607), with_title.bar.title_minimized_accent);
    try testing.expectEqual(@as(?u32, 0x0a0b0c), with_title.bar.run_bg);
    try testing.expectEqual(@as(?u32, 0x070809), with_title.bar.run_fg);
    try testing.expectEqual(@as(?u32, 0x010203), with_title.bar.run_prompt_color);
    try testing.expectEqual(@as(u32, 0x0a0b0c), with_title.bar.runBg());
    try testing.expectEqual(@as(?u32, null), with_title.bar.indicator_color);
}

test "selected workspace tag: per-state composite styling + indicator color" {
    // The selected tag's icon TEXT is styled like any segment: the
    // [bar.properties] "workspaces_selected" entry overlays "workspaces" on the
    // current tag only. Its composite color wins over selected_fg, its flags
    // layer on top of the base entry's; selected_indicator_color stays an
    // independent indicator-glyph knob.
    var cfg = try loadToml(testing.allocator, "selected-tag",
        \\[bar]
        \\primary_color     = "#aa0000"
        \\fg = "#070809"
        \\selected_bg       = primary_color
        \\selected_fg       = "#eeeeee"
        \\selected_indicator_color = "#00ff00"
        \\
        \\[bar.properties]
        \\workspaces_selected = #00ff00 bold
        \\
    );
    defer cfg.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0xEEEEEE), cfg.bar.selected_fg);
    try testing.expectEqual(@as(?u32, 0x00FF00), cfg.bar.selected_indicator_color);
    // Composite entry landed in the segment maps, not a scalar knob field.
    try testing.expectEqual(@as(u32, 0x00FF00), cfg.bar.segment_fg.get("workspaces_selected").?);
    try testing.expectEqual(bar_config.SegmentProps{ .bold = true }, cfg.bar.segment_props.get("workspaces_selected").?);
    // The selected tag uses the composite color and bold weight...
    try testing.expectEqual(@as(u32, 0x00FF00), cfg.bar.workspaceTextFg(true));
    try testing.expectEqual(bar_config.SegmentProps{ .bold = true }, cfg.bar.workspaceIconProps(true));
    // ...while unselected tags keep the bar-wide fg and no style.
    try testing.expectEqual(@as(u32, 0x070809), cfg.bar.workspaceTextFg(false));
    try testing.expectEqual(bar_config.SegmentProps{}, cfg.bar.workspaceIconProps(false));
    // The selected tag's glyph uses its own color; unselected tags keep the
    // shared indicator/bar-fg fallback.
    try testing.expectEqual(@as(u32, 0x00FF00), cfg.bar.workspaceIndicatorColor(true));
    try testing.expectEqual(@as(u32, 0x070809), cfg.bar.workspaceIndicatorColor(false));

    // The base "workspaces" entry styles every tag; "workspaces_selected" is a
    // pure style-only overlay on top of it for the current tag.
    var layered = try loadToml(testing.allocator, "selected-tag-layered",
        \\[bar]
        \\fg = "#070809"
        \\selected_fg = "#eeeeee"
        \\
        \\[bar.properties]
        \\workspaces          = #ff0000 italic
        \\workspaces_selected = bold
        \\
    );
    defer layered.deinit(testing.allocator);
    // No color in the selected overlay: selected text follows the base entry.
    try testing.expectEqual(@as(u32, 0xFF0000), layered.bar.workspaceTextFg(true));
    try testing.expectEqual(@as(u32, 0xFF0000), layered.bar.workspaceTextFg(false));
    // Flags layer: base italic OR'd with the selected tag's bold.
    try testing.expectEqual(
        bar_config.SegmentProps{ .italic = true, .bold = true },
        layered.bar.workspaceIconProps(true),
    );
    try testing.expectEqual(bar_config.SegmentProps{ .italic = true }, layered.bar.workspaceIconProps(false));

    // Absent knobs keep the defaults; with no composite entries the selected
    // tag falls back to selected_fg, the rest to fg, and the selected indicator
    // falls back to indicator_color, then the tag's text color.
    var fallback = try loadToml(testing.allocator, "selected-tag-fallback",
        \\[bar]
        \\fg = "#070809"
        \\selected_fg = "#eeeeee"
        \\indicator_color = "#123456"
        \\
    );
    defer fallback.deinit(testing.allocator);
    try testing.expectEqual(@as(?u32, null), fallback.bar.selected_indicator_color);
    try testing.expectEqual(@as(u32, 0x123456), fallback.bar.workspaceIndicatorColor(true));
    try testing.expectEqual(@as(u32, 0x123456), fallback.bar.workspaceIndicatorColor(false));
    try testing.expectEqual(@as(u32, 0xEEEEEE), fallback.bar.workspaceTextFg(true));
    try testing.expectEqual(@as(u32, 0x070809), fallback.bar.workspaceTextFg(false));

    // With no indicator color at all, the current tag follows the same text
    // color chain and the rest follow fg.
    var fg_fallback = try loadToml(testing.allocator, "selected-tag-fg",
        \\[bar]
        \\fg = "#070809"
        \\selected_fg = "#eeeeee"
        \\
    );
    defer fg_fallback.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0xEEEEEE), fg_fallback.bar.workspaceIndicatorColor(true));
    try testing.expectEqual(@as(u32, 0x070809), fg_fallback.bar.workspaceIndicatorColor(false));
}

test "palette references resolve by full name cross-section" {
    // The four palette vars are the source of truth; color knobs reference
    // them by full name from ANY section, and changing one variable updates
    // the whole color set.
    var refs = try loadToml(testing.allocator, "palette-refs",
        \\[tiling]
        \\border_focused   = primary_color
        \\border_unfocused = secondary_color
        \\
        \\[bar]
        \\primary_color     = "#aa0000"
        \\secondary_color   = "#00bb00"
        \\alternative_color = "#0000cc"
        \\text_color        = "#eeeeee"
        \\bg = "#0a0b0c"
        \\fg = "#070809"
        \\selected_bg = primary_color
        \\
        \\[bar.properties]
        \\title           = primary_color
        \\title_unfocused = secondary_color
        \\title_minimized = alternative_color
        \\
    );
    defer refs.deinit(testing.allocator);

    // tiling borders resolve from the palette.
    try testing.expectEqual(@as(u32, 0xAA0000), refs.tiling.border_focused);
    try testing.expectEqual(@as(u32, 0x00BB00), refs.tiling.border_unfocused);
    // bar-wide palette knobs resolve their literal colors.
    try testing.expectEqual(@as(u32, 0xAA0000), refs.bar.primary_color);
    try testing.expectEqual(@as(u32, 0x00BB00), refs.bar.secondary_color);
    try testing.expectEqual(@as(u32, 0x0000CC), refs.bar.alternative_color);
    try testing.expectEqual(@as(u32, 0xEEEEEE), refs.bar.text_color);
    // [bar.properties] and selected_bg inherit through full-name references.
    try testing.expectEqual(@as(u32, 0xAA0000), refs.bar.selected_bg);
    try testing.expectEqual(@as(u32, 0xAA0000), refs.bar.title_accent_color);
    try testing.expectEqual(@as(u32, 0x00BB00), refs.bar.title_unfocused_accent);
    try testing.expectEqual(@as(u32, 0x0000CC), refs.bar.title_minimized_accent);
}

test "palette: same var in two sections takes the alphabetically later section" {
    // collectPalette picks by section NAME, not by hash-iteration order, so
    // the winner is reproducible: `tiling` sorts after `bar`.
    var cfg = try loadToml(testing.allocator, "palette-two-sections",
        \\[bar]
        \\primary_color = "#aa0000"
        \\
        \\[tiling]
        \\primary_color   = "#00bb00"
        \\border_focused  = primary_color
        \\
        \\[bar.properties]
        \\title = primary_color
        \\
    );
    defer cfg.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 0x00BB00), cfg.tiling.border_focused);
    try testing.expectEqual(@as(u32, 0x00BB00), cfg.bar.title_accent_color);
}

test "per-segment text colors: bar.properties keys override segment fg" {
    var cfg = try loadToml(testing.allocator, "segment-fg",
        \\[bar]
        \\primary_color     = "#aa0000"
        \\secondary_color   = "#00aa00"
        \\alternative_color = "#0000cc"
        \\fg = "#070809"
        \\
        \\[bar.properties]
        \\title               = primary_color
        \\cpu                 = primary_color italic=true
        \\ram                 = primary_color
        \\volume              = alternative_color underline
        \\brightness          = alternative_color bold
        \\brightness_value    = primary_color
        \\clock               = bold underline
        \\cpu_value           = secondary_color
        \\
    );
    defer cfg.deinit(testing.allocator);

    // Systatus readouts read primary; slider controls read alternative.
    try testing.expectEqual(@as(u32, 0xAA0000), cfg.bar.segmentFg("cpu"));
    try testing.expectEqual(@as(u32, 0xAA0000), cfg.bar.segmentFg("ram"));
    try testing.expectEqual(@as(u32, 0x0000CC), cfg.bar.segmentFg("volume"));
    try testing.expectEqual(@as(u32, 0x0000CC), cfg.bar.segmentFg("brightness"));
    // A segment without an entry falls back to the bar-wide fg.
    try testing.expectEqual(@as(u32, 0x070809), cfg.bar.segmentFg("batt"));
    // clock has a style-only entry (no color): its color stays the bar fg.
    try testing.expectEqual(@as(u32, 0x070809), cfg.bar.segmentFg("clock"));
    // The scalar title knob still lands, untouched by the map.
    try testing.expectEqual(@as(u32, 0xAA0000), cfg.bar.title_accent_color);
    try testing.expectEqual(@as(usize, 4), cfg.bar.segment_fg.count());
    // `<name>_value` keys are per-segment NUMBER colors; a segment without one
    // falls back to its own label color (then the bar-wide fg).
    try testing.expectEqual(@as(u32, 0x00AA00), cfg.bar.segmentValueFg("cpu"));
    try testing.expectEqual(@as(u32, 0xAA0000), cfg.bar.segmentValueFg("brightness"));
    try testing.expectEqual(@as(u32, 0x0000CC), cfg.bar.segmentValueFg("volume"));
    try testing.expectEqual(@as(u32, 0xAA0000), cfg.bar.segmentValueFg("ram"));
    try testing.expectEqual(@as(u32, 0x070809), cfg.bar.segmentValueFg("batt"));
    try testing.expectEqual(@as(usize, 2), cfg.bar.segment_value_fg.count());
    // Style flags ride the same composite entry: `underline`/`bold`/`italic`
    // booleans, combinable with a color. Style-only segments keep the default
    // fg and still get their flags.
    try testing.expectEqual(bar_config.SegmentProps{ .italic = true }, cfg.bar.segmentProps("cpu"));
    try testing.expectEqual(bar_config.SegmentProps{ .underline = true }, cfg.bar.segmentProps("volume"));
    try testing.expectEqual(bar_config.SegmentProps{ .bold = true }, cfg.bar.segmentProps("brightness"));
    try testing.expectEqual(bar_config.SegmentProps{ .bold = true, .underline = true }, cfg.bar.segmentProps("clock"));
    // Everything else stays plain; the map holds only non-default entries.
    try testing.expectEqual(bar_config.SegmentProps{}, cfg.bar.segmentProps("ram"));
    try testing.expectEqual(bar_config.SegmentProps{}, cfg.bar.segmentProps("batt"));
    try testing.expectEqual(@as(usize, 4), cfg.bar.segment_props.count());
}

test "per-segment properties: composite entries decode every spelling" {
    var cfg = try loadToml(testing.allocator, "seg-props",
        \\[bar]
        \\fg = "#070809"
        \\
        \\[bar.properties]
        \\a = #aa0000 underline=true
        \\b = #00aa00 bold
        \\c = #0000cc italic
        \\d = bold=true italic=true
        \\e = underline=false
        \\f = underline=1
        \\g = italic=0 bold=true
        \\h = plain
        \\
    );
    defer cfg.deinit(testing.allocator);

    // Color + `name=bool` composite.
    try testing.expectEqual(@as(u32, 0xAA0000), cfg.bar.segmentFg("a"));
    try testing.expectEqual(bar_config.SegmentProps{ .underline = true }, cfg.bar.segmentProps("a"));
    // Bare-flag shorthand (true by default).
    try testing.expectEqual(@as(u32, 0x00AA00), cfg.bar.segmentFg("b"));
    try testing.expectEqual(bar_config.SegmentProps{ .bold = true }, cfg.bar.segmentProps("b"));
    try testing.expectEqual(bar_config.SegmentProps{ .italic = true }, cfg.bar.segmentProps("c"));
    // Style-only entry, no color: fg stays default.
    try testing.expectEqual(@as(u32, 0x070809), cfg.bar.segmentFg("d"));
    try testing.expectEqual(bar_config.SegmentProps{ .bold = true, .italic = true }, cfg.bar.segmentProps("d"));
    // `name=false` clears (a no-op here, so no entry is stored).
    try testing.expectEqual(bar_config.SegmentProps{}, cfg.bar.segmentProps("e"));
    // 0/1 integers spell booleans.
    try testing.expectEqual(bar_config.SegmentProps{ .underline = true }, cfg.bar.segmentProps("f"));
    try testing.expectEqual(bar_config.SegmentProps{ .italic = false, .bold = true }, cfg.bar.segmentProps("g"));
    // An unknown bare token is neither a color nor a flag: warn-and-skip, so
    // the segment stays plain with the default fg.
    try testing.expectEqual(bar_config.SegmentProps{}, cfg.bar.segmentProps("h"));
    try testing.expectEqual(@as(u32, 0x070809), cfg.bar.segmentFg("h"));
    // Only non-default flag sets are stored (a, b, c, d, f, g).
    try testing.expectEqual(@as(usize, 6), cfg.bar.segment_props.count());
}

test "per-segment colors: no [bar.properties] table leaves map empty" {
    var cfg = try loadToml(testing.allocator, "segment-fg-absent",
        \\[bar]
        \\fg = "#070809"
        \\
    );
    defer cfg.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), cfg.bar.segment_fg.count());
    try testing.expectEqual(@as(usize, 0), cfg.bar.segment_value_fg.count());
    try testing.expectEqual(@as(usize, 0), cfg.bar.segment_props.count());
    try testing.expectEqual(@as(u32, 0x070809), cfg.bar.segmentFg("cpu"));
    try testing.expectEqual(bar_config.SegmentProps{}, cfg.bar.segmentProps("cpu"));
}

test "warn-and-revert: out-of-range scalars revert to defaults" {
    var cfg = try loadToml(testing.allocator, "revert",
        \\[bar]
        \\carousel_speed_px_s = 0
        \\font_size = -10%
        \\
        \\[tiling]
        \\gap_width = -50
        \\
        \\[drag]
        \\snap_distance = -1
        \\
        \\[display]
        \\dpi = 5000
        \\
        \\[bar.modules.workspaces]
        \\count = 999
        \\
    );
    defer cfg.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 125), cfg.bar.carousel_speed_px_s);
    try testing.expectEqual(types.ScalableValue.percentage(10.0), cfg.bar.font_size);
    try testing.expectEqual(types.ScalableValue.absolute(10.0), cfg.tiling.gap_width);
    try testing.expectEqual(types.ScalableValue.absolute(8.0), cfg.floating.snap_distance);
    try testing.expectEqual(@as(u8, 9), cfg.workspaces.count);
    // An absurd dpi warns back to null, i.e. to detection, rather than
    // scaling the whole UI by a number nobody meant.
    try testing.expectEqual(@as(?f32, null), cfg.core.dpi);
}

test "bar.position is case-insensitive; unknown spellings keep .top" {
    var bottom = try loadToml(testing.allocator, "pos-bottom",
        \\[bar]
        \\position = "bottom"
        \\
    );
    defer bottom.deinit(testing.allocator);
    try testing.expectEqual(bar_config.BarScreenPosition.bottom, bottom.bar.bar_position);

    // Position parsing is any-case, via BarScreenPosition.string_map through
    // types.enumFromString; "TOP" resolves to .top (not .bottom).
    var shouty = try loadToml(testing.allocator, "pos-shouty",
        \\[bar]
        \\position = "TOP"
        \\
    );
    defer shouty.deinit(testing.allocator);
    try testing.expectEqual(bar_config.BarScreenPosition.top, shouty.bar.bar_position);

    var mixed = try loadToml(testing.allocator, "pos-mixed",
        \\[bar]
        \\position = "Bottom"
        \\
    );
    defer mixed.deinit(testing.allocator);
    try testing.expectEqual(bar_config.BarScreenPosition.bottom, mixed.bar.bar_position);
}

test "layouts array caps at 256 entries" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    // Each layout name takes an optional workspace-list ("1") group slot, so
    // every name + list forms one group of two array elements. 300 names ->
    // 600 elements; the cap check must stop the 257th captured name, not the
    // downstream seed-time registry.
    try buf.appendSlice(testing.allocator, "[tiling]\nlayouts = [");
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        const entry = try std.fmt.allocPrint(testing.allocator, "{s}\"l{d}\", \"1\"", .{ if (i > 0) ", " else "", i });
        defer testing.allocator.free(entry);
        try buf.appendSlice(testing.allocator, entry);
    }
    try buf.appendSlice(testing.allocator, "]\n");

    var cfg = try loadToml(testing.allocator, "layouts-cap", buf.items);
    defer cfg.deinit(testing.allocator);

    // The 256th name is kept ("l255"), the 257th onward ("l256"...) skipped.
    try testing.expectEqual(@as(usize, 256), cfg.tiling.layouts.items.len);
    try testing.expectEqualStrings("l0", cfg.tiling.layouts.items[0]);
    try testing.expectEqualStrings("l255", cfg.tiling.layouts.items[255]);
}

test "config/fallback.toml loads cleanly through the real pipeline" {
    // The shipped fallback doubles as a fixture: it must parse and apply with
    // no skipped lines (no source_path/fallback drift) and produce sane
    // values. "Cleanly" is asserted, not assumed: every warn the load emits
    // lands in the bag, so a knob renamed out from under the fallback (the
    // segment_spacing -> per_segment_padding drift, caught by --check-config)
    // fails here instead of silently reverting to a default.
    const io = std.Options.debug_io;
    const repo_path = try std.Io.Dir.cwd().realPathFileAlloc(io, "config/fallback.toml", testing.allocator);
    defer testing.allocator.free(repo_path);
    var diag: diagnostics.Diagnostics = .{ .allocator = testing.allocator };
    defer diag.deinit();
    const saved = diagnostics.diagnostics;
    diagnostics.diagnostics = &diag;
    defer diagnostics.diagnostics = saved;
    var cfg = try config.loadConfig(testing.allocator, repo_path);
    defer cfg.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 50), cfg.tiling.min_window_dim);
    try testing.expectEqual(bar_config.BarScreenPosition.bottom, cfg.bar.bar_position);
    try testing.expectEqual(@as(usize, 0), diag.count());
}

test "getRatio: bare integers are percentages (indicator_padding)" {
    var cfg = try loadToml(testing.allocator, "ratio-ints",
        \\[bar]
        \\indicator_padding = 1
        \\
    );
    defer cfg.deinit(testing.allocator);
    // The legacy bare-`1` ambiguity rule: `1` means 1%, warned.
    try testing.expectEqual(@as(f32, 0.01), cfg.bar.indicator_padding);

    var pct = try loadToml(testing.allocator, "ratio-pct",
        \\[bar]
        \\indicator_padding = 40%
        \\
    );
    defer pct.deinit(testing.allocator);
    try testing.expectEqual(@as(f32, 0.4), pct.bar.indicator_padding);
}

test "getRatio strict: transparency rejects bare integers" {
    // Bare integers are rejected for transparency: `= 1` would be 1%, but
    // `= 1.0` means 100%. They warn and revert to the default (fully opaque),
    // so only a decimal ratio or a percentage can set transparency.
    var bare = try loadToml(testing.allocator, "transparency-bare",
        \\[bar]
        \\transparency = 1
        \\
    );
    defer bare.deinit(testing.allocator);
    try testing.expectEqual(@as(f32, 1.0), bare.bar.transparency);

    var hundred = try loadToml(testing.allocator, "transparency-hundred",
        \\[bar]
        \\transparency = 100
        \\
    );
    defer hundred.deinit(testing.allocator);
    try testing.expectEqual(@as(f32, 1.0), hundred.bar.transparency);

    // Decimal ratios and percentages still parse.
    var dec = try loadToml(testing.allocator, "transparency-dec",
        \\[bar]
        \\transparency = 0.25
        \\
    );
    defer dec.deinit(testing.allocator);
    try testing.expectEqual(@as(f32, 0.25), dec.bar.transparency);

    var pct = try loadToml(testing.allocator, "transparency-pct",
        \\[bar]
        \\transparency = 50%
        \\
    );
    defer pct.deinit(testing.allocator);
    try testing.expectEqual(@as(f32, 0.5), pct.bar.transparency);
}

test "fragment validate rejects off-range ratio master_width at load" {
    // tiling_config.validate returns error.InvalidConfig, which composed.parse
    // propagates straight out of the load (boot falls back; reload keeps live
    // -- see config.loadFor). The negatives are directly assertable on
    // loadToml, and are covered in config_test's boot case too.
    try testing.expectError(error.InvalidConfig, loadToml(testing.allocator, "mw-big", "[tiling]\nmaster_width = 99%\n"));
    try testing.expectError(error.InvalidConfig, loadToml(testing.allocator, "mw-neg", "[tiling]\nmaster_width = -50\n"));
}

test "load accepts pixel master_width above the ratio ceiling" {
    // The rejection half lives above: 99% ratio and negative pixels are
    // both pinned at the error level. A bare-pixel 600 is a perfectly good
    // absolute width (the screen size is unknown at parse time), so the
    // load must succeed and keep it.
    var px = try loadToml(testing.allocator, "mw-px",
        \\[tiling]
        \\master_width = 600
        \\
    );
    defer px.deinit(testing.allocator);
    try testing.expectEqual(types.ScalableValue.absolute(600.0), px.tiling.master_width);
}

test "workspace and float rules parse from TOML" {
    var cfg = try loadToml(testing.allocator, "rules-float",
        \\[workspace.rules]
        \\terminal  = 3
        \\firefox   = "float"
        \\member    = 7
        \\utils     = "float"
        \\
        \\[rules]
        \\browser = 2
        \\magnet   = "float"
        \\
        \\[workspace.rules.1]
        \\one-app = 1
        \\
    );
    defer cfg.deinit(testing.allocator);

    var float_count: usize = 0;
    var ws_sum: usize = 0;
    var seen_float: usize = 0;
    var n: usize = 0;
    for (cfg.workspaces.rules.items) |rule| {
        if (rule.float) {
            float_count += 1;
            if (std.mem.eql(u8, rule.class_name, "firefox") or
                std.mem.eql(u8, rule.class_name, "utils") or
                std.mem.eql(u8, rule.class_name, "magnet")) seen_float += 1;
        } else {
            ws_sum += rule.workspace;
            n += 1;
        }
    }
    // 3 float rules (firefox, utils, magnet); workspace rules: terminal->2,
    // member->6, browser->1, one-app->0 (1-based input, 0-based storage).
    try testing.expectEqual(@as(usize, 3), float_count);
    try testing.expectEqual(@as(usize, 3), seen_float);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqual(@as(u32, 2 + 6 + 1 + 0), @as(u32, @intCast(ws_sum)));
}

test "color-mix: + mixes resolve end-to-end through knobs, segments, and palette vars" {
    // palette: primary = #aa0000 (170,0,0), secondary = #008800 (0,136,0).
    // Every expectation below is the exact round-half-up channel average.
    var cfg = try loadToml(testing.allocator, "mix-e2e",
        \\[tiling]
        \\border_focused   = primary_color +(weight:25%) secondary_color
        \\border_unfocused = secondary_color + primary_color
        \\
        \\[bar]
        \\primary_color     = "#aa0000"
        \\secondary_color   = "#008800"
        \\alternative_color = primary_color + secondary_color
        \\fg = "#070809"
        \\
        \\[bar.properties]
        \\title = alternative_color
        \\cpu   = primary_color +(weight:40%) secondary_color
        \\ram   = primary_color
        \\
    );
    defer cfg.deinit(testing.allocator);

    // border_focused: 75% primary + 25% secondary
    //   r = (170*75 + 50)/100 = 128 (0x80), g = (136*25 + 50)/100 = 34 (0x22).
    try testing.expectEqual(@as(u32, 0x802200), cfg.tiling.border_focused);
    // border_unfocused: 50/50
    //   r = (170 + 1)/2 = 85 (0x55), g = (136 + 1)/2 = 68 (0x44).
    try testing.expectEqual(@as(u32, 0x554400), cfg.tiling.border_unfocused);
    // alternative_color is itself a palette-declared mix (50/50); bar.properties
    // `title` references it through the collected palette.
    try testing.expectEqual(@as(u32, 0x554400), cfg.bar.title_accent_color);
    // [bar.properties] segment mix: 60% primary + 40% secondary
    //   r = (10200 + 50)/100 = 102 (0x66), g = (5440 + 50)/100 = 54 (0x36).
    try testing.expectEqual(@as(u32, 0x663600), cfg.bar.segmentFg("cpu"));
    // A plain palette reference through the same path stays literal.
    try testing.expectEqual(@as(u32, 0xAA0000), cfg.bar.segmentFg("ram"));
}

test "color-mix: over-budget and head weights revert to the default" {
    // primary_color +(weight:150%) secondary_color sums past 100; the head
    // operand may never carry a weight. Both shape as valid TOML but invalid
    // mixes, so each knob warn-and-reverts to its default color.
    var cfg = try loadToml(testing.allocator, "mix-bad-weight",
        \\[tiling]
        \\border_focused   = primary_color +(weight:150%) secondary_color
        \\border_unfocused = (weight:60%)primary_color + secondary_color
        \\
        \\[bar]
        \\primary_color   = "#aa0000"
        \\secondary_color = "#008800"
        \\
    );
    defer cfg.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0x5294E2), cfg.tiling.border_focused);
    try testing.expectEqual(@as(u32, 0x383C4A), cfg.tiling.border_unfocused);
}

test "color-mix: literal array spelling mixes equally, duplicate palette-name declarations later-win" {
    // C-16 regression: a LITERAL array (bracket spelling) read at a color
    // knob is a bare-operand mix, never corrupted into solid-last via the
    // scalar descent; duplicate palette-*name* declarations keep later-wins
    // (they are NOT a mix to be averaged).
    var cfg = try loadToml(testing.allocator, "c16-literal-vs-dup",
        \\[tiling]
        \\border_focused   = [0xaa0000, 0x008800]
        \\
        \\[bar]
        \\primary_color     = "#aa0000"
        \\secondary_color   = "#008800"
        \\alternative_color = primary_color
        \\alternative_color = secondary_color
        \\
        \\[bar.properties]
        \\title = alternative_color
        \\
    );
    defer cfg.deinit(testing.allocator);

    // border_focused: a literal 2-element array = 50/50 bare-list mix.
    //   r = (170 + 1)/2 = 85 (0x55), g = (136 + 1)/2 = 68 (0x44).
    try testing.expectEqual(@as(u32, 0x554400), cfg.tiling.border_focused);
    // alternative_color declared twice: later-wins (secondary), not a 50/50
    // average of the two palette references.
    try testing.expectEqual(@as(u32, 0x008800), cfg.bar.title_accent_color);
}

test "display.dpi: integer and fractional spellings both widen; absent stays null" {
    // Both spellings reach the same f32 knob: a TOML number with no fraction
    // parses as an integer, one with a fraction as a scalable. A knob that
    // read only one of them would accept `dpi = 144` and ignore `dpi = 144.0`.
    var whole = try loadToml(testing.allocator, "dpi-whole", "[display]\ndpi = 144\n");
    defer whole.deinit(testing.allocator);
    try testing.expectEqual(@as(?f32, 144.0), whole.core.dpi);

    var fraction = try loadToml(testing.allocator, "dpi-frac", "[display]\ndpi = 96.5\n");
    defer fraction.deinit(testing.allocator);
    try testing.expectEqual(@as(?f32, 96.5), fraction.core.dpi);

    // Absent means "auto", which is the difference between this knob being
    // an override and being a replacement for detection.
    var absent = try loadToml(testing.allocator, "dpi-absent", "[bar]\nheight = 30\n");
    defer absent.deinit(testing.allocator);
    try testing.expectEqual(@as(?f32, null), absent.core.dpi);
}

test "[core] key_repeat: explicit true lands; absent keeps the suppress-all default" {
    // The default is the whole point of the knob: held combos must not
    // re-fire side-effecting actions, so a config that never mentions
    // key_repeat has to load with suppression on.
    var absent = try loadToml(testing.allocator, "key-repeat-absent", "[bar]\nenabled = true\n");
    defer absent.deinit(testing.allocator);
    try testing.expectEqual(false, absent.core.key_repeat);

    var on = try loadToml(testing.allocator, "key-repeat-on", "[core]\nkey_repeat = true\n");
    defer on.deinit(testing.allocator);
    try testing.expectEqual(true, on.core.key_repeat);

    var off = try loadToml(testing.allocator, "key-repeat-off", "[core]\nkey_repeat = false\n");
    defer off.deinit(testing.allocator);
    try testing.expectEqual(false, off.core.key_repeat);
}

test "legacy drun_* keys still parse after the rename to run_*" {
    // An UNEDITED existing config must keep working, so the alias path is
    // pinned here rather than assumed: these are the exact key spellings hana
    // shipped, loaded into the canonical run_* fields.
    var legacy = try loadToml(testing.allocator, "drun-alias",
        \\[bar]
        \\primary_color = "#010203"
        \\bg = "#0a0b0c"
        \\fg = "#070809"
        \\drun_prompt = "$ "
        \\
        \\[bar.properties]
        \\drun_bg = "#0a0b0c"
        \\drun_fg = "#070809"
        \\drun_prompt_color = "#010203"
        \\
    );
    defer legacy.deinit(testing.allocator);
    try testing.expectEqualStrings("$ ", legacy.bar.run_prompt.?);
    try testing.expectEqual(@as(?u32, 0x0a0b0c), legacy.bar.run_bg);
    try testing.expectEqual(@as(?u32, 0x070809), legacy.bar.run_fg);
    try testing.expectEqual(@as(?u32, 0x010203), legacy.bar.run_prompt_color);
    // The read-time fallback chain must see the alias exactly as if the
    // canonical key had been used.
    try testing.expectEqual(@as(u32, 0x0a0b0c), legacy.bar.runBg());
    try testing.expectEqual(@as(u32, 0x070809), legacy.bar.runFg());
    try testing.expectEqual(@as(u32, 0x010203), legacy.bar.runPromptColor());
}

test "canonical run_* and legacy drun_* are the same field, not two" {
    // Both spellings target ONE field, so a config cannot end up with a
    // half-applied pair. Whichever the parser sees assigns the same storage;
    // the test pins that the canonical spelling reaches the same values.
    var canonical = try loadToml(testing.allocator, "run-canonical",
        \\[bar]
        \\primary_color = "#010203"
        \\bg = "#0a0b0c"
        \\fg = "#070809"
        \\run_prompt = "$ "
        \\
        \\[bar.properties]
        \\run_bg = "#0a0b0c"
        \\run_fg = "#070809"
        \\run_prompt_color = "#010203"
        \\
    );
    defer canonical.deinit(testing.allocator);
    try testing.expectEqualStrings("$ ", canonical.bar.run_prompt.?);
    try testing.expectEqual(@as(?u32, 0x0a0b0c), canonical.bar.run_bg);
    try testing.expectEqual(@as(?u32, 0x070809), canonical.bar.run_fg);
    try testing.expectEqual(@as(?u32, 0x010203), canonical.bar.run_prompt_color);
}
