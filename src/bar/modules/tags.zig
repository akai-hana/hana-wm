//! Workspace tag indicator.
//! Renders workspace labels and activity glyphs on the status bar.

const types = @import("types");
const drawing = @import("drawing");
const tracking = @import("tracking");
const actions = @import("actions");
const focus = @import("focus");
const build_options = @import("build_options");
const segmod = @import("segment");

/// Reserved row width when no workspaces are configured (moved here from
/// bar.zig: width policy belongs to the segment that owns the pixels).
const fallback_width: u16 = 270;

// Sized to workspace_labels, the largest label source. Every workspace index
// is bounded by tracking.getWorkspaceCount() (<= max_workspaces), so no
// fallback path exists.
var label_widths: [tracking.workspace_labels.len]u16 = [_]u16{0} ** tracking.workspace_labels.len;
var ws_width: u16 = 0;
var cache_valid: bool = false;
// All-view (all_workspaces / Mod+5) collapse: while the flag is active every
// workspace tag is replaced by ONE cell labeled "花", so the whole segment
// narrows to a single tag. The cell is at least the standard tag width,
// growing to fit the (wider) CJK glyph when necessary.
const all_view_label = "花";
var all_view_label_width: u16 = 0;
var all_view_cell_width: u16 = 0;
// Cached horizontal offset of the indicator glyph within a workspace cell.
// Added to the cell's start_x at draw time; constant for all cells.
var cached_ind_x_off: u16 = 0;
// Cached vertical top position of the indicator glyph; constant for all cells.
var cached_ind_y: u16 = 0;

// Returns the display label for workspace `i`, falling back through icons, labels, and "?".
inline fn getLabel(i: usize, config: types.BarConfig) []const u8 {
    if (i < config.workspace_icons.items.len) return config.workspace_icons.items[i];
    if (i < tracking.workspace_labels.len) return tracking.workspace_labels[i];
    return "?";
}

// Invalidates the segment cache; next draw() call will remeasure labels and cell widths.
fn invalidate() void {
    cache_valid = false;
}

// Rebuilds the label-width and geometry cache if stale.
fn ensureCache(
    dc: *drawing.DrawContext,
    config: types.BarConfig,
    height: u16,
    ws_current: u8,
    ws_all_active: bool,
) void {
    if (cache_valid) return;
    const count = @min(tracking.getWorkspaceCount(), label_widths.len);
    // Measure each label with ITS per-state styling: the selected tag may
    // render bold (workspaces_selected), so its glyph is wider than its
    // neighbors.
    for (label_widths[0..count], 0..) |*w, i| {
        const is_current = ws_all_active or (i == ws_current);
        w.* = dc.measureTextWidthStyled(getLabel(i, config), config.workspaceIconProps(is_current));
    }
    ws_width = config.scaledWorkspaceWidth(height);
    // Measure the all-view collapse label with the SELECTED styling: the single
    // all-view cell renders as the current tag, and its CJK glyph is wider than
    // the default numeric tags.
    all_view_label_width = dc.measureTextWidthStyled(all_view_label, config.workspaceIconProps(true));
    all_view_cell_width = @max(ws_width, all_view_label_width);
    cache_valid = true;

    // All geometry inputs are constant between reloads, so the indicator
    // position holds until the next invalidate() + ensureCache() cycle.
    const ind_size = config.scaledIndicatorSize(height);
    const pos = indicatorPos(
        ws_width,
        height,
        ind_size,
        ind_size,
        config.indicator_location,
        config.indicator_padding,
    );
    // pos.x is already the intra-cell offset (computed without a cell_x base).
    cached_ind_x_off = pos.x;
    cached_ind_y = pos.y;
}

// Computes the top-left pixel position of an indicator item within a workspace cell.
fn indicatorPos(
    cell_w: u16,
    bar_height: u16,
    item_w: u16,
    item_h: u16,
    location: types.IndicatorLocation,
    padding: f32,
) struct { x: u16, y: u16 } {
    const cw: f32 = @floatFromInt(cell_w);
    const bh: f32 = @floatFromInt(bar_height);

    // (x, y) anchoring fractions, one per indicator location: the horizontal
    // and vertical anchoring axes respectively.
    const corner: struct { x: f32, y: f32 } = switch (location) {
        .left => .{ .x = 0.0, .y = 0.5 },
        .right => .{ .x = 1.0, .y = 0.5 },
        .up => .{ .x = 0.5, .y = 0.0 },
        .down => .{ .x = 0.5, .y = 1.0 },
        .up_left => .{ .x = 0.0, .y = 0.0 },
        .up_right => .{ .x = 1.0, .y = 0.0 },
        .down_left => .{ .x = 0.0, .y = 1.0 },
        .down_right => .{ .x = 1.0, .y = 1.0 },
    };

    const ax: f32 = corner.x + padding * (0.5 - corner.x);
    const ay: f32 = corner.y + padding * (0.5 - corner.y);

    const iw: f32 = @floatFromInt(item_w);
    const ih: f32 = @floatFromInt(item_h);
    const ix: u16 = @intCast(@max(0, @as(i32, @intFromFloat(@round(ax * cw - iw / 2.0)))));
    const iy: u16 = @intCast(@max(0, @as(i32, @intFromFloat(@round(ay * bh - ih / 2.0)))));
    return .{ .x = ix, .y = iy };
}

// Draws one workspace tag cell: background, centered label, and the window
// indicator glyph when `has_windows`. Shared by the regular per-workspace tags
// and the single all-view collapse cell.
fn drawCell(
    dc: *drawing.DrawContext,
    config: types.BarConfig,
    height: u16,
    x: u16,
    cell_w: u16,
    label: []const u8,
    label_w: u16,
    has_windows: bool,
    is_current: bool,
) !void {
    const bg = if (is_current) config.selected_bg else config.bg;
    const fg = config.workspaceTextFg(is_current);

    dc.fillRect(x, 0, cell_w, height, bg);

    // baselineY returns the same value for every cell; hoist it once outside.
    const text_x = x + (cell_w -| label_w) / 2;
    try dc.drawTextStyled(text_x, dc.baselineY(height), label, fg, config.workspaceIconProps(is_current));

    if (has_windows) {
        const glyph = if (is_current)
            config.indicator_focused orelse types.default_indicator_focused
        else
            config.indicator_unfocused orelse types.default_indicator_unfocused;
        const color = config.workspaceIndicatorColor(is_current);
        // Use the pre-cached intra-cell offset; avoids per-workspace float arithmetic.
        try dc.drawTextSized(x + cached_ind_x_off, cached_ind_y, glyph, config.scaledIndicatorSize(height), color);
    }
}

// Whether any workspace carries at least one window (drives the indicator
// glyph on the all-view collapse cell).
fn anyWorkspaceHasWindows(ws_has_windows: []const bool) bool {
    for (ws_has_windows) |hw| if (hw) return true;
    return false;
}

// Draw workspace tags.
//
// `ws_current`: index of the currently active workspace. `ws_has_windows`:
// one bool per workspace; true when it has at least one window (drives the
// indicator glyph). While `ws_all_active` (the all_workspaces / Mod+5 view)
// the 8+ tags collapse into a single "花" tag rendered as current.
fn drawFrame(
    dc: *drawing.DrawContext,
    config: types.BarConfig,
    height: u16,
    start_x: u16,
    ws_current: u8,
    ws_has_windows: []const bool,
    ws_all_active: bool,
) !u16 {
    if (ws_has_windows.len == 0) return start_x;
    ensureCache(dc, config, height, ws_current, ws_all_active);
    var x = start_x;

    if (ws_all_active) {
        try drawCell(
            dc,
            config,
            height,
            x,
            all_view_cell_width,
            all_view_label,
            all_view_label_width,
            anyWorkspaceHasWindows(ws_has_windows),
            true,
        );
        x += all_view_cell_width;
        return x;
    }

    for (ws_has_windows, 0..) |has_windows, i| {
        try drawCell(dc, config, height, x, ws_width, getLabel(i, config), label_widths[i], has_windows, i == ws_current);
        x += ws_width;
    }
    return x;
}

/// Draw workspace tags: the per-frame frame state (current workspace,
/// per-workspace window flags, all-view) lives in the shared DrawCtx the bar
/// builds every frame, so no separate frame-arg draw signature is needed.
fn draw(ctx: *segmod.DrawCtx, start_x: u16) !u16 {
    const f = ctx.frame;
    return drawFrame(
        ctx.dc,
        ctx.config,
        ctx.height,
        start_x,
        f.current_workspace,
        f.workspace_has_windows,
        f.is_all_view_active,
    );
}

/// This module's bar-segment contribution (registry binding).
fn naturalWidthHook(frame: *const anyopaque, _: u16) u16 {
    const f: *const segmod.Frame = @ptrCast(@alignCast(frame));
    if (f.workspace_count > 0) {
        // All-view collapses 8 tags -> 1: the row reservation narrows with it.
        if (f.is_all_view_active) return all_view_cell_width;
        return @intCast(f.workspace_count * ws_width);
    }
    return fallback_width;
}

fn resolveWorkspaceClick(offset: u16) ?usize {
    // In all-view the single "花" cell represents every workspace at once; a
    // click cannot map onto one workspace, so it is a no-op.
    if (tracking.isAllViewActive()) return null;
    const cell_w = ws_width;
    if (cell_w == 0) return null;
    if (!build_options.has_workspaces) return null;
    const idx: usize = @intCast(offset / cell_w);
    if (idx >= tracking.getWorkspaceCount()) return null;
    return idx;
}

fn onClickHook(
    offset: u16,
    left: bool,
    right: bool,
    _: *anyopaque,
    _: *const fn (*anyopaque, u16) void,
    _: *const fn () void,
) bool {
    const idx = resolveWorkspaceClick(offset) orelse return true;
    if (left) {
        actions.switchTo(@intCast(idx));
    } else if (right) {
        const win = focus.getFocused() orelse return true;
        actions.moveWindowTo(win, @intCast(idx));
    }
    return true;
}

fn drawHook(ctx: *anyopaque, x: u16) !u16 {
    return draw(segmod.castDraw(ctx), x);
}

pub const module: @import("contract").Segment = .{
    .name = "workspaces",
    .clickable = true,
    .dirty_sources = .{ .frame = true },
    .invalidate = invalidate,
    .naturalWidth = naturalWidthHook,
    .draw = drawHook,
    .onClick = onClickHook,
};
