//! Bar's non-scalar config structures: fonts, indicator glyph mirroring,
//! workspace icons, and the bar layout columns (the tables knob.applyAll
//! does not cover). Called from bar_config.parse; every parser is gated on
//! its parent section, and owned strings are duped so they outlive the
//! load-scoped arena.

const std = @import("std");
const log = std.log.scoped(.bar_sections);
const build_options = @import("build_options");
const model = @import("model");
const parser = @import("parser");
const knob = @import("knob");
const types = @import("types");
const bar_config = @import("bar_config");
const segmod = @import("segment");

/// One row of the bar-anchor table driving both the default layout and the
/// per-anchor `[bar.layout.<name>]` sections, so the anchor set can't drift.
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

/// `appendDupedStrings`'s comptime `warn` argument: segment list warns on a
/// stray non-string entry (a typo should be called out); fonts list doesn't.
const warn_bad_segment_entries = true;
const ignore_bad_font_entries = false;

/// Dupe-appends every string element of `items` into `dst`, optionally
/// formatting integers as decimal strings (`ints_as_numbers`, the
/// workspace-icons form). Non-string entries are skipped; with `warn` set
/// they also surface a warning.
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

/// Every bar SCALAR is driven by knob.applyAll; everything here stays
/// gated on the [bar] section existing.
pub fn parseBar(allocator: std.mem.Allocator, doc: *parser.Document, cfg: *bar_config.Config) !void {
    const section = doc.getSection(types.section_bar) orelse return;
    if (section.getAsOrWarn([]const parser.Value, "fonts")) |arr| {
        types.freeStrings(&cfg.fonts, allocator, types.keep_capacity);
        try appendDupedStrings(ignore_bad_font_entries, false, allocator, arr, &cfg.fonts);
        log.info("Loaded {} fonts for bar", .{cfg.fonts.items.len});
    }
    // If only one of indicator_focused/unfocused is set, the other mirrors
    // it: a pair interaction, so it stays bespoke rather than joining the
    // knob table.
    const raw_focused = section.getAs([]const u8, "indicator_focused");
    const raw_unfocused = section.getAs([]const u8, "indicator_unfocused");
    const focused_val = raw_focused orelse raw_unfocused;
    const unfocused_val = raw_unfocused orelse raw_focused;
    if (focused_val) |v| try knob.assignStr(allocator, &cfg.indicator_focused, v);
    if (unfocused_val) |v| try knob.assignStr(allocator, &cfg.indicator_unfocused, v);
    try parseWorkspaceIcons(allocator, section, doc, cfg);
    try parseBarLayout(allocator, doc, cfg);
}

/// Workspace-count source for icon padding: `[bar.modules.workspaces]
/// count`, else `[workspaces] count`, else default. Read straight off the
/// DOCUMENT so the bar fragment has no cross-fragment dependency on the
/// optional workspaces module.
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

/// Formats integer `n` as decimal and dupes it to a string.
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
/// labeled the way document.zig's private fileLabel does ("" labels as
/// "<input>"). Only called on a section whose `segments` was just read, so
/// the entry always exists; the fallback is defensive.
fn segmentsSource(section: *parser.Section) struct { file: []const u8, line: usize } {
    for (section.entries.items) |e| {
        if (std.mem.eql(u8, e.key, "segments"))
            return .{ .file = if (e.file.len == 0) "<input>" else e.file, .line = e.line };
    }
    return .{ .file = "<input>", .line = 0 };
}

/// Load-time rejection of an unknown segment name in a `[bar.layout.<anchor>]`
/// column. Consumers skip unresolvable names, so a typo would render nothing
/// unless rejected here with the file:line of the `segments` declaration.
/// The registry is comptime, so this knows at load time. Both guards are
/// comptime so a tree without segment dispatch or with no registered
/// segments (the "all segments removed" modularity scenario, whose fallback
/// layout lists names that no longer exist) compiles the check away rather
/// than failing to boot. Every unknown name is reported before returning.
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
    // would die instead of degrading). The shipped-layout-names-all-resolve
    // contract stays pinned by the tests that load the same bytes under a
    // file label; only the boot-floor path skips.
    if (std.mem.eql(u8, src.file, types.embedded_fallback_label)) return;
    var bad = false;
    for (seg_arr) |v| {
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

/// Rejects a segment listed more than once across the configured layout: a
/// second instance would paint twice but live in the FIRST-match
/// click-bound table, and a self-ticking duplicate would region-repaint only
/// its last-recorded slot, leaving the other stale. Warn-and-skip (softer
/// than rejectUnknownSegments): a duplicate is a rendering nuisance; an
/// unknown NAME renders nothing at all.
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
