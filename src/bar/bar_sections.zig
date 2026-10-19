//! Bar's non-scalar config structures: fonts, indicator glyph mirroring,
//! workspace icons, and the bar layout columns -- the tables the knob engine
//! (bar_config.knobs via knob.applyAll) does not cover. Called from
//! bar_config.parse; every parser here is gated on its parent section
//! existing, exactly as the scalar knobs are, and every owned string it
//! stores is duped off the parsed document so it outlives the load-scoped
//! arena.

const std = @import("std");
const log = std.log.scoped(.bar_sections);
const build_options = @import("build_options");
const model = @import("model");
const parser = @import("parser");
const knob = @import("knob");
const types = @import("types");
const bar_config = @import("bar_config");
const segmod = @import("segment");

/// One row of the bar-anchor table driving both the default bar layout
/// (initDefaultBarLayout) and the per-anchor `[bar.layout.<name>]` sections
/// (parseBarLayout), so the anchor set can never drift.
const BarAnchorInfo = struct {
    name: []const u8,
    position: bar_config.BarSegmentAnchor,
    default_seg: []const u8,
};

const bar_anchors = [_]BarAnchorInfo{
    .{ .name = "left", .position = .left, .default_seg = "workspaces" },
    .{ .name = "center", .position = .center, .default_seg = "title" },
    .{ .name = "right", .position = .right, .default_seg = "clock" },
};

pub fn initDefaultBarLayout(allocator: std.mem.Allocator, cfg: *bar_config.Config) !void {
    for (bar_anchors) |a| {
        var layout = bar_config.BarLayout{ .position = a.position, .segments = .empty };
        try layout.segments.append(allocator, try allocator.dupe(u8, a.default_seg));
        try cfg.layout.append(allocator, layout);
    }
}

/// `appendDupedStrings`'s comptime `warn` argument meanings: the bar segment
/// list warns on a stray non-string entry (a typo should be called out), the
/// fonts list silently ignores it.
const warn_bad_segment_entries = true;
const ignore_bad_font_entries = false;

/// Dupe-appends every string element of `items` into `dst`, optionally also
/// formatting integer elements as decimal strings (`ints_as_numbers`, the
/// workspace-icons form). Non-string entries are skipped; with `warn` set
/// they also surface a warning (the bar segment list, where a typo should be
/// called out, vs. the fonts list, where a stray non-string is simply
/// ignored).
fn appendDupedStrings(
    comptime warn: bool,
    comptime ints_as_numbers: bool,
    allocator: std.mem.Allocator,
    items: []const parser.Value,
    dst: *std.ArrayList([]const u8),
) !void {
    var skipped = false;
    for (items) |item| {
        if (item.asScalar([]const u8)) |s| {
            try dst.append(allocator, try allocator.dupe(u8, s));
            continue;
        }
        if (comptime ints_as_numbers) {
            if (item.asScalar(i64)) |n| {
                try dst.append(allocator, try dupeNum(allocator, n));
                continue;
            }
        }
        skipped = true;
    }
    if (warn and skipped)
        log.warn("Non-string entry in bar segment list, skipping", .{});
}

/// Bar's NON-scalar structures: fonts, indicator glyph mirroring, workspace
/// icons, and the bar columns. Every bar SCALAR (flags, scalables, height,
/// colors incl. the [bar.properties] fallback chains, strings, enums, ratios)
/// is driven by knob.applyAll; like parseBar always did, everything here
/// stays gated on the [bar] section existing.
pub fn parseBar(allocator: std.mem.Allocator, doc: *parser.Document, cfg: *bar_config.Config) !void {
    const section = doc.getSection(types.section_bar) orelse return;
    if (section.getAsOrWarn([]const parser.Value, "fonts")) |arr| {
        types.freeStrings(&cfg.fonts, allocator, types.keep_capacity);
        try appendDupedStrings(ignore_bad_font_entries, false, allocator, arr, &cfg.fonts);
        log.info("Loaded {} fonts for bar", .{cfg.fonts.items.len});
    }
    // indicator_focused/unfocused: if only one is set, the other mirrors it.
    // A pair interaction, so it stays bespoke rather than joining the table.
    const raw_focused = section.getAs([]const u8, "indicator_focused");
    const raw_unfocused = section.getAs([]const u8, "indicator_unfocused");
    const focused_val = raw_focused orelse raw_unfocused;
    const unfocused_val = raw_unfocused orelse raw_focused;
    if (focused_val) |v| try knob.assignStr(allocator, &cfg.indicator_focused, v);
    if (unfocused_val) |v| try knob.assignStr(allocator, &cfg.indicator_unfocused, v);
    try parseWorkspaceIcons(allocator, section, doc, cfg);
    try parseBarLayout(allocator, doc, cfg);
}

/// The workspace-count source for icon padding: `[bar.modules.workspaces]
/// count` first-present, else `[workspaces] count`, else the default 9. Read
/// straight off the DOCUMENT (never off the workspaces fragment's Config)
/// so the bar fragment has no cross-fragment dependency on the optional
/// workspaces module (the count knob itself belongs to workspaces_config).
fn workspaceCountFromDoc(doc: *parser.Document) u8 {
    inline for (.{ types.section_bar_modules_workspaces, types.section_workspaces }) |sec_name| {
        if (doc.getSection(sec_name)) |sec| {
            if (sec.getAs(i64, "count")) |n| {
                if (n >= 1 and n <= model.max_workspaces) return @intCast(n);
            }
        }
    }
    return types.default_workspace_count;
}

pub fn padWorkspaceIcons(allocator: std.mem.Allocator, doc: *parser.Document, cfg: *bar_config.Config) !void {
    const count = workspaceCountFromDoc(doc);
    while (cfg.workspace_icons.items.len < count) {
        try cfg.workspace_icons.append(allocator, try dupeNum(allocator, cfg.workspace_icons.items.len + 1));
    }
}

/// Formats integer `n` as decimal and dupes it to a string, the "int ->
/// string icon" step shared by parseWorkspaceIcons and padWorkspaceIcons.
fn dupeNum(allocator: std.mem.Allocator, n: anytype) ![]u8 {
    return std.fmt.allocPrint(allocator, "{}", .{n});
}

fn parseWorkspaceIcons(
    allocator: std.mem.Allocator,
    section: *parser.Section,
    doc: *parser.Document,
    cfg: *bar_config.Config,
) !void {
    types.freeStrings(&cfg.workspace_icons, allocator, types.keep_capacity);
    if (section.getAs([]const parser.Value, "icons")) |arr| {
        try appendDupedStrings(false, true, allocator, arr, &cfg.workspace_icons);
    } else if (section.getAsOrWarn([]const u8, "icons")) |str| {
        var ch_buf: [1]u8 = undefined;
        for (str) |ch| {
            ch_buf[0] = ch;
            try cfg.workspace_icons.append(allocator, try allocator.dupe(u8, &ch_buf));
        }
    }

    try padWorkspaceIcons(allocator, doc, cfg);
}

fn parseBarLayout(allocator: std.mem.Allocator, doc: *parser.Document, cfg: *bar_config.Config) !void {
    bar_config.freeBarLayouts(&cfg.layout, allocator, types.keep_capacity);
    const max_anchor_name_len = comptime blk: {
        var longest: usize = 0;
        for (bar_anchors) |a| longest = @max(longest, a.name.len);
        break :blk longest;
    };
    var section_buf: [types.section_prefix_bar_layout.len + max_anchor_name_len]u8 = undefined;
    for (bar_anchors) |a| {
        const layout_section = doc.getSection(std.fmt.bufPrint(&section_buf, "{s}{s}", .{ types.section_prefix_bar_layout, a.name }) catch unreachable) orelse continue;
        var bar_layout = bar_config.BarLayout{ .position = a.position, .segments = .empty };
        if (layout_section.getAs([]const parser.Value, "segments")) |seg_arr| {
            // BEFORE the append: a rejection leaves this row unallocated
            // (prior rows free through composed.parse's errdefer chain).
            try rejectUnknownSegments(layout_section, a.name, seg_arr);
            try appendDupedStrings(warn_bad_segment_entries, false, allocator, seg_arr, &bar_layout.segments);
        }
        if (bar_layout.segments.items.len > 0) try cfg.layout.append(allocator, bar_layout) else bar_layout.deinit(allocator);
    }
    rejectDuplicateSegments(allocator, cfg);

    if (cfg.layout.items.len == 0) try initDefaultBarLayout(allocator, cfg);
}

/// Source attribution for the first `segments` declaration in `section`,
/// the P1-43 entry fields applied the way document.zig's private fileLabel
/// does ("" from an entry built without one labels as "<input>"). Only
/// called on a section whose `segments` key has just been read, so the
/// entry always exists; the fallback is defensive.
fn segmentsSource(section: *parser.Section) struct { file: []const u8, line: usize } {
    for (section.entries.items) |e| {
        if (std.mem.eql(u8, e.key, "segments"))
            return .{ .file = if (e.file.len == 0) "<input>" else e.file, .line = e.line };
    }
    return .{ .file = "<input>", .line = 0 };
}

/// Load-time rejection of an unknown segment name in a `[bar.layout.<anchor>]`
/// column (P1-46). Every layout consumer skips an unresolvable name
/// (`segmod.segId(name) orelse continue`), so a typo'd name used to load
/// clean and simply render nothing; the fail bar now rejects the config with
/// the file:line of the `segments` declaration instead. The registry is
/// comptime, so this knows at load time, not just at render.
///
/// Both guards are comptime so a tree without the bar's segment dispatch
/// (`has_bar` off — `segment.zig` itself is gone) or one with no registered
/// segments (the "all segments removed" modularity scenario, whose fallback
/// layout lists names that no longer exist) compiles the check away rather
/// than failing to boot on names it could never resolve.
///
/// Every unknown name in the list is reported before returning, so one load
/// tells the user about all of them, not just the first.
fn rejectUnknownSegments(
    section: *parser.Section,
    anchor: []const u8,
    seg_arr: []const parser.Value,
) error{InvalidConfig}!void {
    if (comptime !build_options.has_bar) return;
    if (comptime !segmod.hasRegisteredSegments()) return;
    const src = segmentsSource(section);
    // The build's OWN embedded fallback never rejects: loadFor falls back to
    // exactly this source, so a tree that deleted one of its layout segments
    // would take the floor down with the user config it just rejected (boot
    // would die instead of degrading). The full-tree contract that the
    // shipped layout names all resolve stays pinned by the tests that load
    // the same bytes under a file label (fallback_test, the knob_test
    // fallback pipeline test) -- only the boot-floor path skips.
    if (std.mem.eql(u8, src.file, types.embedded_fallback_label)) return;
    var bad = false;
    for (seg_arr) |v| {
        // Non-strings are appendDupedStrings' warn-and-skip, unchanged.
        const name = v.asScalar([]const u8) orelse continue;
        if (segmod.segId(name) != null) continue;
        log.err(
            "Bar: segment '{s}' in [bar.layout.{s}] is not registered in this build ({s}:{d}); rejecting the config (check the spelling, or whether this build includes the segment's module)",
            .{ name, anchor, src.file, src.line },
        );
        bad = true;
    }
    if (bad) return error.InvalidConfig;
}

/// Rejects a segment listed more than once across the whole configured
/// layout. A second instance is dropped with a warning: it would paint twice
/// but live in the FIRST-match click-bound table (the later instance's hit
/// test resolves to the earlier slot) and a self-ticking duplicate would
/// region-repaint only its last-recorded slot, leaving the other stale.
/// Warn-and-skip is deliberately softer than the sibling check above: a
/// duplicate is a rendering nuisance, an unknown NAME renders nothing at
/// all (rejectUnknownSegments, which fails the load instead).
fn rejectDuplicateSegments(allocator: std.mem.Allocator, cfg: *bar_config.Config) void {
    for (cfg.layout.items, 0..) |*lay, ri| {
        var keep: usize = 0;
        for (lay.segments.items) |name| {
            var dup = false;
            rows: for (cfg.layout.items[0..ri]) |prior_row| {
                for (prior_row.segments.items) |prior| {
                    if (std.mem.eql(u8, prior, name)) {
                        dup = true;
                        break :rows;
                    }
                }
            }
            if (!dup) {
                for (lay.segments.items[0..keep]) |prior| {
                    if (std.mem.eql(u8, prior, name)) {
                        dup = true;
                        break;
                    }
                }
            }
            if (dup) {
                log.warn(
                    "Bar: segment '{s}' is listed more than once; keeping only its first occurrence",
                    .{name},
                );
                allocator.free(name);
                continue;
            }
            lay.segments.items[keep] = name;
            keep += 1;
        }
        lay.segments.shrinkRetainingCapacity(keep);
    }
}
