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
//! Scratch files are created by src/test/config/scratch.zig in a per-process
//! uniquely-named directory under the system temp area; each test cleans up
//! after itself.

const std = @import("std");
const testing = std.testing;

// The tests deliberately exercise warn-and-revert / layouts-cap
// diagnostics; src/core/utils/debug.zig silences all std.log diagnostics in
// test binaries, so this stays quiet on success.
const config = @import("config");
const parser = @import("parser");
const schema = @import("schema");
const types = @import("types");
const scratch = @import("scratch");

fn scratchPath(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
    const toml = try std.fmt.allocPrint(alloc, "{s}.toml", .{name});
    defer alloc.free(toml);
    return scratch.scratchPath(alloc, "hana-schema-", toml);
}

/// Loads a TOML string through the full production pipeline
/// (parse -> buildConfigFromDoc), like a real config file would be.
fn loadToml(alloc: std.mem.Allocator, name: []const u8, content: []const u8) !types.Config {
    const path = try scratchPath(alloc, name);
    defer alloc.free(path);
    try scratch.writeScratchFile(path, content);
    defer scratch.cleanupScratch(path);
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

test "types.Config{} carries sensible field initializers" {
    const proto: types.Config = .{};
    try testing.expect(proto.bar.enabled);
    try testing.expect(proto.fullscreen_enabled);
    try testing.expectEqual(@as(u8, 9), proto.workspaces.count);
    try testing.expectEqual(@as(u32, 0x222222), proto.bar.bg);
    try testing.expectEqual(@as(u32, 0x61AFEF), proto.bar.primary_color);
    try testing.expectEqual(types.MasterSide.left, proto.tiling.master_side);
    try testing.expectEqual(types.BarScreenPosition.top, proto.bar.bar_position);
    try testing.expectEqual(types.ScalableValue.percentage(50.0), proto.tiling.master_width);
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
    try testing.expectEqual(types.ScalableValue.percentage(60.0), dedicated.tiling.master_width);
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
    try testing.expectEqual(types.ScalableValue.absolute(7.0), sub.tiling.gap_width);
    try testing.expectEqual(@as(u32, 0x112233), sub.tiling.border_focused);

    // A lone [tiling.aesthetics] (no [tiling] functional marker) still feeds
    // the quartet: the values are visual, so a theme-only file applies them --
    // this is exactly the shape akai.toml ships today.
    var lone = try loadToml(testing.allocator, "aesthetics-lone",
        \\[tiling.aesthetics]
        \\gap_width = 7
        \\
    );
    defer lone.deinit(testing.allocator);
    try testing.expectEqual(types.ScalableValue.absolute(7.0), lone.tiling.gap_width);
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
    try testing.expectEqual(types.ScalableValue.absolute(20.0), cfg.bar.spacing);
    try testing.expectEqual(@as(u8, 4), cfg.workspaces.count);
    // Icons padded to the workspace count after the explicit entry.
    try testing.expectEqual(@as(usize, 4), cfg.bar.workspace_icons.items.len);
}

test "fallback chains: title/drun colors follow their siblings" {
    // Regime 1: no [bar.properties] at all. The accent trio was UNCONDITIONALLY
    // assigned its fallback sibling (now the palette canon: primary_color /
    // secondary_color / alternative_color); the drun trio were left untouched (null),
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
    try testing.expectEqual(@as(?u32, null), no_colors.bar.drun_bg);
    try testing.expectEqual(@as(?u32, null), no_colors.bar.drun_prompt_color);
    try testing.expectEqual(@as(u32, 0x010203), no_colors.bar.drunPromptColor());

    // Regime 2: [bar.properties] present with only `title`. The accent trio now
    // reads per-key (absent keys copy their sibling); the drun trio are also
    // assigned -- copying siblings when their own keys are absent, exactly
    // like the old `if (colors)` block.
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
    try testing.expectEqual(@as(?u32, 0x0a0b0c), with_title.bar.drun_bg);
    try testing.expectEqual(@as(?u32, 0x070809), with_title.bar.drun_fg);
    try testing.expectEqual(@as(?u32, 0x010203), with_title.bar.drun_prompt_color);
    try testing.expectEqual(@as(u32, 0x0a0b0c), with_title.bar.drunBg());
    try testing.expectEqual(@as(?u32, null), with_title.bar.indicator_color);
}

test "palette references resolve by full name cross-section" {
    // The four palette vars are the source of truth; color knobs reference
    // them by full name from ANY section, and changing one variable updates
    // the whole color set.
    var refs = try loadToml(testing.allocator, "palette-refs",
        \\[tiling]
        \\[tiling.aesthetics]
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
        \\mem                 = primary_color
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
    try testing.expectEqual(@as(u32, 0xAA0000), cfg.bar.segmentFg("mem"));
    try testing.expectEqual(@as(u32, 0x0000CC), cfg.bar.segmentFg("volume"));
    try testing.expectEqual(@as(u32, 0x0000CC), cfg.bar.segmentFg("brightness"));
    // A segment without an entry falls back to the bar-wide fg.
    try testing.expectEqual(@as(u32, 0x070809), cfg.bar.segmentFg("batt"));
    // clock has a style-only entry (no color): its color stays the bar fg.
    try testing.expectEqual(@as(u32, 0x070809), cfg.bar.segmentFg("clock"));
    // The scalar title knob still lands, untouched by the map pass.
    try testing.expectEqual(@as(u32, 0xAA0000), cfg.bar.title_accent_color);
    try testing.expectEqual(@as(usize, 4), cfg.bar.segment_fg.count());
    // `<name>_value` keys are per-segment NUMBER colors; a segment without one
    // falls back to its own label color (then the bar-wide fg).
    try testing.expectEqual(@as(u32, 0x00AA00), cfg.bar.segmentValueFg("cpu"));
    try testing.expectEqual(@as(u32, 0xAA0000), cfg.bar.segmentValueFg("brightness"));
    try testing.expectEqual(@as(u32, 0x0000CC), cfg.bar.segmentValueFg("volume"));
    try testing.expectEqual(@as(u32, 0xAA0000), cfg.bar.segmentValueFg("mem"));
    try testing.expectEqual(@as(u32, 0x070809), cfg.bar.segmentValueFg("batt"));
    try testing.expectEqual(@as(usize, 2), cfg.bar.segment_value_fg.count());
    // Style flags ride the same composite entry: `underline`/`bold`/`italic`
    // booleans, combinable with a color. Style-only segments keep the default
    // fg and still get their flags.
    try testing.expectEqual(types.SegmentProps{ .italic = true }, cfg.bar.segmentProps("cpu"));
    try testing.expectEqual(types.SegmentProps{ .underline = true }, cfg.bar.segmentProps("volume"));
    try testing.expectEqual(types.SegmentProps{ .bold = true }, cfg.bar.segmentProps("brightness"));
    try testing.expectEqual(types.SegmentProps{ .bold = true, .underline = true }, cfg.bar.segmentProps("clock"));
    // Everything else stays plain; the map holds only non-default entries.
    try testing.expectEqual(types.SegmentProps{}, cfg.bar.segmentProps("mem"));
    try testing.expectEqual(types.SegmentProps{}, cfg.bar.segmentProps("batt"));
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
    try testing.expectEqual(types.SegmentProps{ .underline = true }, cfg.bar.segmentProps("a"));
    // Bare-flag shorthand (true by default).
    try testing.expectEqual(@as(u32, 0x00AA00), cfg.bar.segmentFg("b"));
    try testing.expectEqual(types.SegmentProps{ .bold = true }, cfg.bar.segmentProps("b"));
    try testing.expectEqual(types.SegmentProps{ .italic = true }, cfg.bar.segmentProps("c"));
    // Style-only entry, no color: fg stays default.
    try testing.expectEqual(@as(u32, 0x070809), cfg.bar.segmentFg("d"));
    try testing.expectEqual(types.SegmentProps{ .bold = true, .italic = true }, cfg.bar.segmentProps("d"));
    // `name=false` clears (a no-op here, so no entry is stored).
    try testing.expectEqual(types.SegmentProps{}, cfg.bar.segmentProps("e"));
    // 0/1 integers spell booleans.
    try testing.expectEqual(types.SegmentProps{ .underline = true }, cfg.bar.segmentProps("f"));
    try testing.expectEqual(types.SegmentProps{ .italic = false, .bold = true }, cfg.bar.segmentProps("g"));
    // An unknown bare token is neither a color nor a flag: warn-and-skip, so
    // the segment stays plain with the default fg.
    try testing.expectEqual(types.SegmentProps{}, cfg.bar.segmentProps("h"));
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
    try testing.expectEqual(types.SegmentProps{}, cfg.bar.segmentProps("cpu"));
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
    try testing.expectEqual(types.ScalableValue.percentage(10.0), cfg.bar.font_size);
    try testing.expectEqual(types.ScalableValue.absolute(10.0), cfg.tiling.gap_width);
    try testing.expectEqual(types.ScalableValue.absolute(8.0), cfg.snap_distance);
    try testing.expectEqual(@as(u8, 9), cfg.workspaces.count);
}

test "bar.position is case-insensitive; unknown spellings keep .top" {
    var bottom = try loadToml(testing.allocator, "pos-bottom",
        \\[bar]
        \\position = "bottom"
        \\
    );
    defer bottom.deinit(testing.allocator);
    try testing.expectEqual(types.BarScreenPosition.bottom, bottom.bar.bar_position);

    // C8: now any-case, via BarScreenPosition.string_map through
    // types.enumFromString; "TOP" resolves to .top (not .bottom).
    var shouty = try loadToml(testing.allocator, "pos-shouty",
        \\[bar]
        \\position = "TOP"
        \\
    );
    defer shouty.deinit(testing.allocator);
    try testing.expectEqual(types.BarScreenPosition.top, shouty.bar.bar_position);

    var mixed = try loadToml(testing.allocator, "pos-mixed",
        \\[bar]
        \\position = "Bottom"
        \\
    );
    defer mixed.deinit(testing.allocator);
    try testing.expectEqual(types.BarScreenPosition.bottom, mixed.bar.bar_position);
}

test "S2: layouts array caps at 256 entries" {
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

test "C11: config/fallback.toml loads cleanly through the real pipeline" {
    // The shipped fallback doubles as a fixture: it must parse and apply with
    // no skipped lines (no source_path/fallback drift) and produce sane values.
    const io = std.Options.debug_io;
    const repo_path = try std.Io.Dir.cwd().realPathFileAlloc(io, "config/fallback.toml", testing.allocator);
    defer testing.allocator.free(repo_path);
    var cfg = try config.loadConfig(testing.allocator, repo_path);
    defer cfg.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 50), cfg.tiling.min_window_dim);
    try testing.expect(cfg.tiling.enabled);
    try testing.expectEqual(types.BarScreenPosition.bottom, cfg.bar.bar_position);
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
        \\[tiling.aesthetics]
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
        \\mem   = primary_color
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
    try testing.expectEqual(@as(u32, 0xAA0000), cfg.bar.segmentFg("mem"));
}

test "color-mix: over-budget and head weights revert to the default" {
    // primary_color +(weight:150%) secondary_color sums past 100; the head
    // operand may never carry a weight. Both shape as valid TOML but invalid
    // mixes, so each knob warn-and-reverts to its default color.
    var cfg = try loadToml(testing.allocator, "mix-bad-weight",
        \\[tiling]
        \\[tiling.aesthetics]
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
