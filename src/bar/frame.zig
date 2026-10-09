//! Per-frame live-state collection: reads the workspace/window model, title
//! cache and minimized set into the bar's frame scratch (`scanLiveFrame`,
//! `fillDrawCtx`, `titleGeom`), plus the hidden-set synthesis thunk
//! (`minimizedCollect`).
//!
//! Split OUT of `state.zig` in Phase 4 (step 23): these walk model/query
//! state on every draw and fill the ctx the paint pass consumes, so
//! `repaint.zig` calls them -- but they hold no X11 (titles come from the
//! WM-owned cache, geoms from the sync truth-rect), keeping this file a pure
//! reader beside `state.zig`.

const std = @import("std");
const build_options = @import("build_options");
const focus = @import("focus");
const pipeline = @import("pipeline");
const model = @import("model");
const reconcile = @import("reconcile");
const query = @import("query");
const wincache = @import("wincache");
const window = @import("window");
const segmod = @import("segment");
const state = @import("state");

const State = state.State;

/// The hide-family provider bound to the generated window registry, resolved
/// once at file scope: the hidden-set synthesis and its collect dispatch
/// share one lookup (no module is ever named by the bar).
const collect_hidden_set = window.providerOf(.collectHiddenSet);

/// Fills the shared per-frame DrawCtx the bar hands to every segment's
/// draw hook, including the title snapshot slots.
pub fn fillDrawCtx(s: *State, ctx: *segmod.DrawCtx) void {
    ctx.frame = s.frame.frame;
    ctx.frame.workspace_has_windows = s.frame.ws_has_windows[0..s.frame.frame.workspace_count];
    // The minimized-state service is drawn from the window module registry
    // here (upfront, per frame) so the title segment need not name the
    // addon that owns it. No provider compiled in => empty api =>
    // scanLiveFrame no-ops, matching prior boot ordering.
    var minimized_api: segmod.MinimizedApi = .{};
    if (collect_hidden_set != null)
        minimized_api.collect = minimizedCollect;
    ctx.minimized_api = minimized_api;
    // Titles/geoms below come from the WM-owned title cache and the sync
    // truth-rect -- neither performs X11 work, so the draw path is
    // non-blocking and no positional batch exists to scramble. The backing
    // entries live on State, valid for the rest of the frame AND for
    // post-draw click handling through the cached `frame.last_ctx`.
    const entries = s.frame.entries[0..s.frame.entries_len];
    for (entries) |*e| {
        e.title = wincache.peekTitle(e.window);
        e.geom = titleGeom(e.window, s.title_data.minimized.contains(e.window));
    }
    // Title of the minimized window, used in the single-window title case.
    var minimized_title: []const u8 = "";
    if (entries.len > 0 and s.title_data.minimized.contains(entries[0].window))
        minimized_title = entries[0].title;
    ctx.focused_window = focus.getFocused();
    // Copy, do not borrow: `peekTitle` returns a slice of the
    // cache's own storage, and this ctx outlives the draw through
    // `frame.last_ctx`. See focused_title_buf.
    if (ctx.focused_window) |fw| {
        const src = wincache.peekTitle(fw);
        @memcpy(s.title_data.focused_title_buf[0..src.len], src);
        ctx.focused_title = s.title_data.focused_title_buf[0..src.len];
    } else {
        ctx.focused_title = "";
    }
    ctx.minimized_title = minimized_title;
    ctx.current_ws_entries = entries;
    ctx.minimized_set = &s.title_data.minimized;
}

// Live-state collection

/// Reads workspace/window state into the frame fields. Pure model reads:
/// no X11. The per-window titles/geoms are filled later (fillDrawCtx)
/// straight from the WM-owned title cache and the sync truth-rect, so
/// there is no fetch key to diff and nothing to prefetch.
pub fn scanLiveFrame(s: *State) void {
    const m = pipeline.model();
    // The minimized set feeds the title snapshot; the title addon owns the
    // synthesis, exposed through the cached DrawCtx api. Synthesizing
    // fresh each scan makes set membership equivalent to a live
    // per-window query.
    if (build_options.has_minimize) {
        if (s.title_data.minimized_api.collect) |f| f(m, &s.title_data.minimized, s.render.allocator);
    }
    if (build_options.has_workspaces) {
        s.frame.frame.workspace_count = @intCast(query.getWorkspaceCount());
        s.frame.frame.current_workspace = @intCast(m.current.index);
        s.frame.frame.is_all_view_active = m.all_view_active;
        @memset(&s.frame.ws_has_windows, false);
        s.frame.entries_len = 0;
        const cur_ws: model.WSId = model.WSId.fromIndex(s.frame.frame.current_workspace);
        const cur_bit: u64 = if (s.frame.frame.current_workspace < s.frame.frame.workspace_count)
            model.bit(cur_ws)
        else
            0;
        // OR-accumulate all window masks in a single pass, collecting the
        // current workspace's windows on the way.
        var combined_mask: u64 = 0;
        for (query.allWindowsInto(&s.snapshot)) |entry| {
            combined_mask |= entry.mask;
            if (cur_bit != 0 and model.maskedOn(entry.mask, cur_ws) and
                s.frame.entries_len < state.max_frame_windows)
            {
                // Id only: fillDrawCtx annotates title + geom before any
                // draw reads the entry.
                s.frame.entries[s.frame.entries_len] = .{
                    .window = entry.win,
                    .title = "",
                    .geom = null,
                };
                s.frame.entries_len += 1;
            }
        }
        for (0..s.frame.frame.workspace_count) |i| {
            s.frame.ws_has_windows[i] = model.maskedOn(combined_mask, model.WSId.fromIndex(i));
        }
    }
}

/// Canonical title-slot geometry for `win`: the off-screen sentinel while
/// minimized, else the sync truth-rect (floating anchor / last sent rect)
/// with the off-screen sentinel for windows that have never been placed
/// (parked/unsent). Mirrors the old batch behavior (truth-rect first,
/// sentinel fallback) without the xcb_get_geometry round-trip.
fn titleGeom(win: u32, minimized: bool) ?model.Rect {
    if (minimized) return segmod.offscreen_rect;
    return reconcile.truthRect(pipeline.model(), win) orelse segmod.offscreen_rect;
}

/// Full hidden-set synthesis forwarded to the hide-family provider
/// (DrawCtx api signature).
fn minimizedCollect(
    m: *const anyopaque,
    set: *std.AutoHashMapUnmanaged(u32, void),
    allocator: std.mem.Allocator,
) void {
    const mm: *const model.Model = @ptrCast(@alignCast(m));
    if (collect_hidden_set) |wm|
        wm.collectHiddenSet.?(mm, set, allocator);
}
