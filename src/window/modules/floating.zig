//! Floating window interaction and geometry management.
//! Handles drag-to-move and per-corner drag-to-resize for floating windows,
//! including work-area snapping, size-hint constraints (PMin/PMax envelope
//! plus PAspect ratio-accurate resize, Shift to break the band), and paced
//! geometry commits (resize capped to the client repaint budget; moves at
//! display rate). Tiled windows: a CENTER press still detaches to floating
//! on first motion, but an EDGE/CORNER press under the master layout
//! adjusts the adjacent split in place and stays tiled (D26 -- grabEdge /
//! planTiledSplit classify the press; the split rides the keybind actions'
//! ledger-diffed retile). Also updates floating rects on the model and honors
//! configure requests for floating windows, exposing operations via the
//! floating window module contract.
//!
//! Feature-choice note (D26, "no float module" builds): this whole file --
//! drag engine, detach, and split path alike -- lives in the OPTIONAL
//! floating module. Deleting it drops DragHooks to the contract's no-op
//! default, so Super+drag simply does nothing rather than half-detaching a
//! tiled window; there is no separate no-float branch to maintain, and the
//! split gesture goes with it because the classifier that owns the press
//! (classifyMousePress -> startDrag) is itself a floating-module hook.

const std = @import("std");
const builtin = @import("builtin");

const core = @import("core");
const build_options = @import("build_options");
const types = @import("types");

const window = @import("window");
const registry = @import("registry");
const focus = @import("focus");
const query = @import("query");

const hz = @import("hz");

const pipeline = @import("pipeline");
const usable_area = @import("usable_area");
const reconcile_tails = @import("reconcile_tails");

const model = @import("model");
const scaling = @import("scaling");
const reconcile = @import("reconcile");
const contract = @import("tiling_contract");

const DragMode = enum { move, resize, tiled_split };

/// Corner closest to the cursor at drag-start; the opposite corner is the
/// anchor that stays fixed during the resize. Crossing the anchor on an axis
/// wraps the resize to grow the opposite way instead of collapsing. `pub`
/// alongside DragState as the vocabulary of the pure test seams.
pub const ResizeCorner = enum { top_left, top_right, bottom_left, bottom_right };

/// Which window edge a drag-start grab sits on (D26). `pub` as the vocabulary
/// of the pure grab-classification and split-planning test seams.
pub const GrabEdge = enum { left, right, top, bottom };

/// The split knob an edge-drag adjusts (D26): the master/stack boundary is
/// `primary_width`, an interior stack divider is `secondary_balance`.
pub const SplitKnob = enum { primary, balance };

/// Plan for one tiled edge-drag, resolved once at drag start. The snapshot
/// value plus the pixel->ratio denominators let every motion commit apply
/// (start + mapped-delta) - current, which self-corrects at the knob's
/// clamp instead of drifting when a target lands outside the bounds.
pub const TiledSplit = struct {
    knob: SplitKnob = .primary,
    /// dx->primary sign: -1 when the master sits on the right (dragging the
    /// boundary right then narrows the master, matching its geometry).
    sign: f32 = 1,
    /// The knob's value when the drag started.
    start: f32 = 0,
    /// Pixel->ratio denominators, resolved from the work area at drag start.
    wa_w: f32 = 1,
    wa_h: f32 = 1,
};

/// Pixel band around a tiled window's edge where a grab classifies as an
/// edge (split) grab rather than a center (float) grab. Small enough that a
/// center drag to move a window keeps working; wide enough to catch the
/// seam: adjacent panes sit one half-gap + border apart, and each pane's own
/// edge lies within this band of the physical divider.
const edge_band: i32 = 8;

/// Nearest window edge within `edge_band` of (x, y), or null for a center
/// grab (the D26 "center -> existing float-detach" arm). A corner grab
/// resolves to its nearest edge; ties go to the vertical pair first (the
/// master/stack boundary is THE gesture, so its edge must win a corner tie).
/// Pure: the whole classification rule is testable headlessly.
pub fn grabEdge(x: i16, y: i16, rect: model.Rect) ?GrabEdge {
    const px: i32 = x;
    const py: i32 = y;
    const x0: i32 = rect.x;
    const y0: i32 = rect.y;
    const x1: i32 = rect.x + @as(i32, rect.width);
    const y1: i32 = rect.y + @as(i32, rect.height);
    var best_dist: i32 = edge_band + 1;
    var best: ?GrabEdge = null;
    // @abs is unsigned in 0.16 (its result is the unsigned counterpart), so
    // cast back; both endpoints are screen coordinates, so the signed
    // distance cannot overflow i32.
    const cand = [_]struct { GrabEdge, i32 }{
        .{ .left, @intCast(@abs(px - x0)) },
        .{ .right, @intCast(@abs(px - x1)) },
        .{ .top, @intCast(@abs(py - y0)) },
        .{ .bottom, @intCast(@abs(py - y1)) },
    };
    for (cand) |c| {
        if (c[1] <= edge_band and c[1] < best_dist) {
            best_dist = c[1];
            best = c[0];
        }
    }
    return best;
}

/// Resolves an edge grab into the split a tiled edge-drag adjusts, or null
/// when the grab has no split behind it (D26's routing rules; null falls
/// back to the existing center/float-detach behavior):
///
///   - left/right edge -> `primary_width`: the vertical boundary (or an
///     outer vertical edge, where D26 routes it to master width anyway) is
///     the horizontal knob, signed by master side.
///   - top/bottom edge, window in the STACK, interior divider -> `balance`.
///     The workarea-outer test doubles as the partner test: an edge pinned
///     to the workarea border has no divider beside it, and a lone stack
///     window's edges are all outer, so balance only ever moves a real
///     divider. (The knob boosts the first/last stack slots, so an interior
///     middle divider maps in the same direction, approximately.)
///   - top/bottom edge of a MASTER-column window (row dividers) -> null:
///     no knob backs them (D26 scopes balance to the stack).
///
/// `layout` is the caller-resolved registry module (`contract.moduleOf`);
/// anything but master maps to null (no primary/balance behind it, so the
/// drag detaches to float as before). The primary_count slot test is the
/// obvious index rule; the engine's row-fit cap can make the effective
/// master column shorter on small workareas, and this approximation only
/// misroutes that rare geometry to a knob with no visible effect, never to
/// wrong layout behavior.
pub fn planTiledSplit(
    m: *const model.Model,
    win: model.WindowId,
    edge: GrabEdge,
    rect: model.Rect,
    wa: model.Rect,
    primary_on_right: bool,
    layout: ?*const contract.Layout,
) ?TiledSplit {
    const lm = layout orelse return null;
    if (!std.mem.eql(u8, lm.name, "master")) return null;
    const ws = &m.ws[m.current.index];
    const p = ws.params;
    const base: TiledSplit = .{
        .sign = if (primary_on_right) -1 else 1,
        .start = 0,
        .wa_w = @floatFromInt(wa.width),
        .wa_h = @floatFromInt(wa.height),
    };
    switch (edge) {
        .left, .right => {
            var s = base;
            s.knob = .primary;
            s.start = p.primary_width;
            return s;
        },
        .top, .bottom => {
            const idx = ws.tiled_order.indexOfScalar(win) orelse return null;
            if (idx < p.primary_count) return null; // master rows: no knob
            const outer = if (edge == .top)
                rect.y <= wa.y
            else
                @as(i32, rect.y) + @as(i32, rect.height) >= wa.y + @as(i32, wa.height);
            if (outer) return null;
            var s = base;
            s.knob = .balance;
            s.start = p.secondary_balance;
            return s;
        },
    }
}

/// The pixel->ratio delta mapping: total displacement since drag start, in
/// knob units. Vertical edges map dx to the primary-width ratio (signed by
/// master side); interior stack dividers map dy to the balance ratio (a
/// downward drag grows the upper side, matching balance's top-slot boost).
/// Pure; the commit applies `start + mapped` against the LIVE knob value.
pub fn mappedSplitDelta(split: TiledSplit, dx: i32, dy: i32) f32 {
    return switch (split.knob) {
        .primary => split.sign * (@as(f32, @floatFromInt(dx)) / split.wa_w),
        .balance => @as(f32, @floatFromInt(dy)) / split.wa_h,
    };
}

/// Work-area edges struct. `pub` alongside DragState/HintLimits as the
/// vocabulary of the pure `computeResizeRect` test seam.
pub const WaEdges = struct { left: i32, right: i32, top: i32, bottom: i32 };

/// Snapshot of one drag's state. `pub` as the vocabulary of the pure
/// `computeResizeRect` test seam (production code reaches the live drag only
/// through g_state).
pub const DragState = struct {
    active: bool = false,
    window: core.WindowId = 0,
    mode: DragMode = .move,
    /// Plan resolved at drag start when mode == .tiled_split; the defaults
    /// sit inert in move/resize drags (same shape as resize_corner).
    split: TiledSplit = .{},
    resize_corner: ResizeCorner = .bottom_right,
    start_x: i16 = 0,
    start_y: i16 = 0,
    start_win_x: i16 = 0,
    start_win_y: i16 = 0,
    start_win_width: u16 = 0,
    start_win_height: u16 = 0,
    /// Resolved once at drag start: snap distance in pixels (0 = disabled) and
    /// the work-area edges used for snapping. Both are constant for the whole
    /// drag, so re-resolving them on every motion event would be wasted work.
    snap_px: i32 = 0,
    workarea: WaEdges = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },
    /// Throttle geometry commits to the commit rate below to cut redundant
    /// configures on high-poll mice. We still compute the latest rect from
    /// every motion event (preserving responsiveness), but only push to X
    /// when at least one commit period has elapsed since the last commit.
    last_commit_ns: u64 = 0,
    pending_rect: ?model.Rect = null,
    /// Last rect actually pushed to X this drag; a pending rect equal to it
    /// is a sub-pixel jiggle and is dropped -- re-sending the same size would
    /// only make the client repaint for a frame that shows nothing new.
    last_committed: ?model.Rect = null,
};

/// Client repaint budget for resize commits, in Hz.
///
/// Every resize commit forces the client to repaint (video players like mpv
/// recreate their swapchain per size change). Client repaint capacity -- not
/// display refresh -- is the binding constraint: pacing resize to a high-Hz
/// panel's rate buries clients in work they cannot finish, so stale content
/// and border strips pile up along the drag path until the button is
/// released. 60 Hz is the rate every client can sustain; move drags need no
/// client repaint (pure server-side copy) and keep the full refresh rate.
const max_resize_commit_hz: f64 = 60.0;

/// Snap distance from config, resolved to pixels (0 = disabled).
/// Percentages are relative to screen width.
fn snapDistance() i32 {
    const cs = core.getState();
    const sv = cs.config.floating.snap_distance;
    if (sv.value == 0) return 0;
    const sw: f32 = @floatFromInt(cs.screen.width_in_pixels);
    return @intFromFloat(@round(scaling.scaleToPixels(sv, sw)));
}

/// Work-area edges, accounting for the bar and border width. X positions a
/// window's content area, so far edges are pulled in by 2*border_width to
/// keep the outer border flush with the screen edge.
fn workarea() WaEdges {
    const cs = core.getState();
    const bw2: i32 = @as(i32, core.borderWidth()) * 2;
    const work = usable_area.workArea(cs.screen);
    return .{
        .left = work.x,
        .right = work.x + @as(i32, work.width) - bw2,
        .top = work.y,
        .bottom = work.y + @as(i32, work.height) - bw2,
    };
}

/// Snap a coordinate to the near/far edge within `snap` pixels (both window
/// and cursor grounds, per the two callers).
inline fn snapAxis(pos: i32, dim: i32, near: i32, far: i32, snap: i32) i32 {
    if (@abs(pos - near) < snap) return near;
    if (@abs((pos + dim) - far) < snap) return far - dim;
    return pos;
}

/// Resize corner nearest the cursor at a given point: the corners'
/// nearest-point cells are the quadrants through the window's center, so
/// the press quadrant names the corner. Every press maps to a corner —
/// border, edge, or interior — rather than only border-adjacent grabs
/// resolving off the bottom-right fallback. `pub` as the vocabulary of
/// the pure corner-selection test seam.
pub fn nearestResizeCorner(x: i16, y: i16, rect: model.Rect) ResizeCorner {
    const mid_x: i32 = rect.x + @divTrunc(@as(i32, rect.width), 2);
    const mid_y: i32 = rect.y + @divTrunc(@as(i32, rect.height), 2);
    const west: bool = @as(i32, x) < mid_x;
    const north: bool = @as(i32, y) < mid_y;
    if (west and north) return .top_left;
    if (!west and north) return .top_right;
    if (west and !north) return .bottom_left;
    return .bottom_right;
}

const State = struct {
    drag: DragState = .{},
    pending_float: bool = false,
};

var g_state: State = .{};

/// Re-arms the process-global drag state.
///
/// `startDrag` returns early while a drag is active, so a leaked drag does
/// not merely report a stale `isDragging()` -- it makes every later
/// startDrag a no-op. This is the shared reset behind the module's
/// `init`/`deinit` bindings below (window.init / window.deinit's uniform
/// fan-out, P1-39), and the fixture calls it directly for the same reason
/// it calls minimize's and fullscreen's: `g_state` is process-global state
/// a test can leave dirty, and unlike a model store there is no
/// fresh-per-test value to paper over it.
pub fn resetState() void {
    g_state = .{};
}

/// Lifecycle binding (P1-39): mirrors minimize/fullscreen so a leaked drag
/// cannot survive a deinit()+init() cycle (session restart, test harness) --
/// `window.init`'s fan-out re-arms a clean slate, `window.deinit`'s clears it.
pub fn init() anyerror!void {
    resetState();
}

pub fn deinit() void {
    resetState();
}

/// Test-only seam: leaves a drag ACTIVE, standing in for a test that never
/// reached its `stopDrag`.
///
/// Needed because the real `startDrag` calls `core.getState()`, so the leak
/// this item is about cannot be reproduced headlessly any other way. Guarded
/// on `builtin.is_test` so production code cannot reach it.
pub fn seedLeakedDragForTest(win: model.WindowId) void {
    if (!builtin.is_test) @panic("floating.seedLeakedDragForTest is test-only");
    g_state = .{ .drag = .{ .active = true, .window = win } };
}

/// Begins a move (button 1) or resize (button 3) drag on `win` at (x, y).
/// No-op if a drag is already active, or for bar/fullscreen windows.
pub fn startDrag(win: u32, button: u8, x: i16, y: i16) void {
    const cs = core.getState();
    if (g_state.drag.active) return;
    if (usable_area.isSurfaceWindow(win)) return;
    if (model.isCovering(pipeline.state(), win)) return;

    // Reject unmanaged/foreign windows: a drag on a window the WM does not own
    // would no-op every setFloatingRect/dragRect (store.getPtr fails) while
    // g_state.drag.active stays latched, blocking all future drags. The
    // getGeometry fallback below is only for managed-but-never-placed windows,
    // so require store membership before it.
    if (pipeline.state().store.get(win) == null) return;

    // Model/sync truth (floating base or last-sent rect) over a live XCB
    // round-trip; fall back to a live query when never placed.
    const cur = blk: {
        if (reconcile.truthRect(pipeline.state(), win)) |g| break :blk g;
        break :blk window.getGeometry(cs.conn, win) orelse return;
    };

    const resize_corner: ResizeCorner = if (button == 1)
        .bottom_right
    else
        nearestResizeCorner(x, y, cur);

    // D26: classify the grab. An edge/corner press on a TILED window under
    // the MASTER layout adjusts the adjacent split in place (the window
    // stays tiled); a CENTER press -- or any edge with no split behind it --
    // keeps today's float-detach for every button. Button 1 vs 3 keeps its
    // usual meaning on the float path (move vs corner resize) and does not
    // gate the split path: position is the classifier, the classic
    // drag-the-border model.
    const split_plan: ?TiledSplit = if (query.isTiledMode(win)) blk: {
        const m = pipeline.state();
        const edge = grabEdge(x, y, cur) orelse break :blk null;
        break :blk planTiledSplit(
            m,
            win,
            edge,
            cur,
            usable_area.workArea(core.getState().screen),
            primaryOnRight(),
            contract.moduleOf(m.ws[m.current.index].params.kind),
        );
    } else null;

    // Snap distance and work area are resolved here so updateDrag's per-event
    // path only does arithmetic. They are constant for the duration of a drag.
    const snap_px = snapDistance();
    g_state = .{
        .drag = .{
            .active = true,
            .window = win,
            .mode = if (split_plan != null)
                .tiled_split
            else if (button == 1)
                .move
            else
                .resize,
            .split = split_plan orelse .{},
            .resize_corner = resize_corner,
            .start_x = x,
            .start_y = y,
            .start_win_x = cur.x,
            .start_win_y = cur.y,
            .start_win_width = cur.width,
            .start_win_height = cur.height,
            .snap_px = snap_px,
            .workarea = if (snap_px > 0)
                workarea()
            else
                .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },
        },
        // A base-tiled window detaches to floating on first motion (see
        // updateDrag); move also skips snap on that first event so the
        // window doesn't appear frozen at a tiled edge. The split path
        // never detaches -- that is the whole D26 distinction.
        .pending_float = split_plan == null and query.isTiledMode(win),
    };
    focus.grabFocus(win, .user_command);
    // Raise the dragged window immediately outside any server grab (grabFocus
    // has already ungrabAndFlush'd); routed through the shared sink's
    // sanctioned stack primitive + flush so wire stays in sync. Drag ticks
    // keep going flushless via the local dragRect's targeted reconcile
    // (1 configure, no grab).
    //
    // Skipped on the split path: tiling owns stacking (the same rule the
    // focus etiquette's `raise and !isTiledMode` encodes), and the window
    // never leaves its tiled frame.
    if (split_plan == null) {
        const s = pipeline.syncSink();
        s.stackOnly(win, .above);
        // Record the raise at the top of the float raise order. A press on a
        // still-tiled window is fine: the order's replay filters by anchor, so
        // the slot stays inert until the detach, which then inherits the top
        // position the drag deserves.
        reconcile.floatRaise(win);
        s.flush();
    }
}

/// Master side from config, mirrored from pipeline.tilingEnv's comptime gate
/// (absent-tiling builds have no tiling config field; they also never reach
/// a split plan -- the layout registry is empty -- so the default here is
/// only a compile-time shape).
inline fn primaryOnRight() bool {
    if (comptime !build_options.has_tiling) return false;
    return core.getState().config.tiling.master_side == .right;
}

fn computeMoveRect(
    drag: DragState,
    dx: i32,
    dy: i32,
    wa: WaEdges,
    was_pending_float: bool,
) model.Rect {
    const snap = drag.snap_px;
    const raw_x: i32 = @as(i32, drag.start_win_x) + dx;
    const raw_y: i32 = @as(i32, drag.start_win_y) + @as(i32, dy);
    const win_w: i32 = drag.start_win_width;
    const win_h: i32 = drag.start_win_height;
    // Raw drag coords are unbounded i32; pin down to the i16 wire range
    // before the narrowing cast so a window dragged beyond +/-32767 (or into
    // negative X11 coords) can't UB in ReleaseFast.
    const mx: i16 = model.satI16(if (was_pending_float)
        raw_x
    else
        snapAxis(raw_x, win_w, wa.left, wa.right, snap));
    const my: i16 = model.satI16(if (was_pending_float)
        raw_y
    else
        snapAxis(raw_y, win_h, wa.top, wa.bottom, snap));
    return .{
        .x = mx,
        .y = my,
        .width = drag.start_win_width,
        .height = drag.start_win_height,
    };
}

/// Min/max outer size envelope for `win` (the drag-resize / configure-request
/// clamp bounds), plus the full hints record for the aspect fit (the one
/// store lookup serves both policies, so they cannot see different snapshots
/// of the same window's hints). `pub` as the vocabulary of the pure
/// `computeResizeRect` test seam.
pub const HintLimits = struct { min_w: i32, min_h: i32, max_w: i32, max_h: i32, hints: model.SizeHints };

/// The ONE PMin/PMax clamp policy, shared by the drag-resize path and the
/// ConfigureRequest path so the two cannot drift: separate clamps could
/// disagree about borders or the global floor.
///
/// Units are OUTER: an X11 configured width/height excludes the frame, so each
/// non-zero hint grows by both border widths (`bw2`). `min_dim` is the global
/// `min_window_dim` floor, passed as 0 by headless model tests, which have no
/// core to read it from. A zero hint means no constraint (floor 0, ceiling the
/// u16 wire limit), and the `@max(floor, ...)` ceiling keeps a client whose
/// declared max is below its min from inverting the clamp range.
fn sizeEnvelope(hints: model.SizeHints, bw2: i32, min_dim: i32) HintLimits {
    const unbounded: i32 = @as(i32, std.math.maxInt(u16));
    return .{
        .min_w = @max(min_dim, if (hints.min_width == 0) 0 else @as(i32, hints.min_width) + bw2),
        .min_h = @max(min_dim, if (hints.min_height == 0) 0 else @as(i32, hints.min_height) + bw2),
        .max_w = if (hints.max_width == 0) unbounded else @as(i32, hints.max_width) + bw2,
        .max_h = if (hints.max_height == 0) unbounded else @as(i32, hints.max_height) + bw2,
        .hints = hints,
    };
}

/// `sizeEnvelope` for the live-core drag path: border width and the global
/// minimum are always available there.
fn sizeHintLimits(win: u32) HintLimits {
    const bw2: i32 = @as(i32, core.borderWidth()) * 2;
    const min_dim: i32 = if (comptime build_options.has_tiling)
        core.getState().config.tiling.min_window_dim
    else
        types.default_min_window_dim;
    // Window may withdraw mid-drag; treat it as hint-less (no constraint).
    const hints = (pipeline.state().store.get(win) orelse return .{
        .min_w = min_dim,
        .min_h = min_dim,
        .max_w = @as(i32, std.math.maxInt(u16)),
        .max_h = @as(i32, std.math.maxInt(u16)),
        .hints = .{},
    }).size_hints;
    return sizeEnvelope(hints, bw2, min_dim);
}

/// Resize-drag geometry, pure over its inputs (the one impure half, the
/// hint lookup, is resolved by the caller and passed in as `limits`). `pub`
/// as the headless test seam for the drag math.
/// `break_aspect` (Shift held) frees the PAspect band for this tick; the
/// PMin/PMax envelope still applies.
pub fn computeResizeRect(
    drag: DragState,
    dx: i32,
    dy: i32,
    wa: WaEdges,
    limits: HintLimits,
    break_aspect: bool,
) model.Rect {
    const snap = drag.snap_px;
    // Max outer size from the window's PMaxSize hints. X11 configure
    // width/height excludes the frame, so the outer ceiling is the hint
    // plus the border on both sides. A drag resize that ignored these
    // would let the user grow a hint-constrained window past what its
    // client declared, then fight the client's own configure-request
    // reduction on every later drag tick.
    // Anchor = corner opposite the grabbed one, fixed; the moving
    // corner follows the cursor. min/max(anchor, moving) per axis
    // makes crossing the anchor flip growth automatically.
    const axes: struct { left: bool, top: bool } = switch (drag.resize_corner) {
        .top_left => .{ .left = true, .top = true },
        .top_right => .{ .left = false, .top = true },
        .bottom_left => .{ .left = true, .top = false },
        .bottom_right => .{ .left = false, .top = false },
    };
    const start_x: i32 = drag.start_win_x;
    const start_y: i32 = drag.start_win_y;
    const start_w: i32 = drag.start_win_width;
    const start_h: i32 = drag.start_win_height;

    const anchor_x: i32 = start_x + @as(i32, if (axes.left) start_w else 0);
    const anchor_y: i32 = start_y + @as(i32, if (axes.top) start_h else 0);
    const moving_x0: i32 = start_x + @as(i32, if (axes.left) 0 else start_w);
    const moving_y0: i32 = start_y + @as(i32, if (axes.top) 0 else start_h);
    const raw_moving_x: i32 = moving_x0 + dx;
    const raw_moving_y: i32 = moving_y0 + dy;
    const moving_x: i32 = snapAxis(raw_moving_x, 0, wa.left, wa.right, snap);
    const moving_y: i32 = snapAxis(raw_moving_y, 0, wa.top, wa.bottom, snap);

    const new_left: i32 = @min(anchor_x, moving_x);
    const new_right: i32 = @max(anchor_x, moving_x);
    const new_top: i32 = @min(anchor_y, moving_y);
    const new_bottom: i32 = @max(anchor_y, moving_y);

    // Clamp size first, then re-pin position off the anchor so the anchor edge
    // never drifts when a bound is hit. `limits` already carries the global
    // floor plus the PMin/PMax + border envelope (sizeEnvelope), and the
    // `@max(floor, ...)` ceiling keeps a client whose declared max is below its
    // min from inverting the clamp range.
    var clamped_w: i32 = std.math.clamp(new_right - new_left, limits.min_w, @max(limits.min_w, limits.max_w));
    var clamped_h: i32 = std.math.clamp(new_bottom - new_top, limits.min_h, @max(limits.min_h, limits.max_h));
    // PAspect band (the ratio-accurate resize): shrink the excess dimension
    // into the declared ratio so a fixed-shape client (video player) never
    // drags into letterboxing. AFTER the PMin/PMax clamp (the ratio wins over
    // a declared minimum on the derived axis, per aspectFit) and BEFORE the
    // anchor pin (so the fixed corner stays fixed through the shrink). The
    // clamped dims are non-negative and within the u16 wire ceiling, so the
    // narrowing cast is safe.
    if (!break_aspect) {
        const fit = limits.hints.aspectFit(@intCast(clamped_w), @intCast(clamped_h));
        clamped_w = fit.width;
        clamped_h = fit.height;
    }
    const pinned_x: i32 = if (moving_x < anchor_x) anchor_x - clamped_w else new_left;
    const pinned_y: i32 = if (moving_y < anchor_y) anchor_y - clamped_h else new_top;

    return .{
        .x = model.satI16(pinned_x),
        .y = model.satI16(pinned_y),
        .width = @intCast(clamped_w),
        .height = @intCast(clamped_h),
    };
}

/// First motion of a drag on a tiled window detaches it to floating at its
/// current geometry (pending-float detach + remove + retile). Shares the
/// detach transition with the toggle_floating action through
/// `model.detachTiledToFloating` (one spelling, ledger lookup at the caller);
/// this module reaches model/pipeline directly rather than round-tripping
/// through the action layer.
fn detachToFloating(win: core.WindowId) bool {
    const m = pipeline.mut();
    const e = m.store.getPtr(win) orelse return false;
    if (model.isCovering(m, win)) return false;
    if (e.anchor != .tiled) return false;
    const r = reconcile.lastRectFor(win) orelse return false;
    model.detachTiledToFloating(m, e, win, r);
    pipeline.reconcileGrab(.{});
    return true;
}

/// Drag tick (no grab): targeted reconcile — sends ONLY the dragged
/// window's geometry (1 XCB call) instead of replaying all windows. On every
/// motion event; the rect lands through this module's own setFloatingRect
/// hook (we ARE the provider, so no providerOf round trip).
fn dragRect(win: core.WindowId, r: model.Rect) void {
    const m = pipeline.mut();
    setFloatingRect(m, win, r);
    reconcile.reconcileDragTick(m, pipeline.syncSink(), win);
}

/// Applies pointer motion to the active drag. No-op if no drag is active.
/// `break_aspect` (Shift held at the motion event) frees the resize from the
/// window's PAspect band for this tick; it is ignored for move drags.
/// Commit period for a drag rate, capped at 1000Hz. Shared by the rect
/// throttle (below) and the split throttle so the two paths cannot drift
/// apart on the cap.
fn commitPeriodNs(rate: f64) u64 {
    const min_period_ns: u64 = 1_000_000_000 / 1000;
    if (rate <= 0.0) return min_period_ns;
    const p = @as(f64, 1_000_000_000.0) / rate;
    return @max(@as(u64, @intFromFloat(@ceil(p))), min_period_ns);
}

/// One throttled commit of a tiled edge-drag (D26): map the total pixel
/// displacement to knob units, then apply the gap between the DESIRED value
/// (drag-start snapshot + mapped delta) and the LIVE model value. Re-reading
/// the live value every commit is what makes the knob's internal clamp
/// (min/max master width, balance swing) self-correcting: once a bound
/// catches the target, further dragging accumulates in `desired` and the
/// first motion back resumes exactly where the pointer is, with no drift.
///
/// Throttled to the resize budget: each commit retiles both adjacent panes,
/// whose clients repaint on every geometry we send them -- same concern,
/// same cap, per-mode rate chosen here (the rect switch never sees this
/// mode, see the early return in updateDrag).
///
/// Delta mapping and the per-commit reconcile both ride the existing
/// keybind actions (`adjust*` are exactly what mod+j / mod+shift+j do), so
/// the ledger-diffed retile path is the proven one and no new wire entry
/// exists. A no-tiling build never plans a split (empty layout registry ->
/// planTiledSplit null), so this fn is unreachable there by construction.
fn commitTiledSplit(drag: *DragState, dx: i32, dy: i32) void {
    const s = drag.split;
    const rate: f64 = @min(hz.detectedHz(), max_resize_commit_hz);
    const now = core.monotonicNs();
    if (now - drag.last_commit_ns < commitPeriodNs(rate)) return;
    drag.last_commit_ns = now;

    const m = pipeline.state();
    const p = m.ws[m.current.index].params;
    const desired = s.start + mappedSplitDelta(s, dx, dy);
    const live: f32 = switch (s.knob) {
        .primary => p.primary_width,
        .balance => p.secondary_balance,
    };
    const delta = desired - live;
    if (delta == 0) return;
    switch (s.knob) {
        .primary => window.adjustPrimaryWidthAction(delta),
        .balance => window.adjustSecondaryBalance(delta),
    }
}

pub fn updateDrag(x: i16, y: i16, break_aspect: bool) void {
    if (!g_state.drag.active) return;
    const drag = &g_state.drag;

    const was_pending_float = g_state.pending_float;
    if (g_state.pending_float) {
        g_state.pending_float = false;
        // Abort the drag when the detach fails: the window is still tiled, so
        // every setFloatingRect/dragRect would no-op and g_state.drag.active
        // would latch a dead drag that blocks future drags. Clear it instead.
        if (!detachToFloating(drag.window)) {
            drag.active = false;
            return;
        }
    }

    // Widen BEFORE subtracting: start_x/start_y and x/y are i16, and a drag
    // spanning >32767px on a large (or multi-monitor) virtual desktop would
    // wrap the i16 difference, teleporting the window across the usable area.
    // Promote to i32 (used throughout computeMoveRect/computeResizeRect) so
    // the delta is computed in the wider type.
    const dx: i32 = @as(i32, x) - @as(i32, drag.start_x);
    const dy: i32 = @as(i32, y) - @as(i32, drag.start_y);

    // D26: the split path never touches the rect machinery -- it retiles the
    // layout from the model instead of configuring a floating frame.
    if (drag.mode == .tiled_split) {
        commitTiledSplit(drag, dx, dy);
        return;
    }

    const wa = drag.workarea;

    const rect = switch (drag.mode) {
        .move => computeMoveRect(drag.*, dx, dy, wa, was_pending_float),
        .resize => computeResizeRect(drag.*, dx, dy, wa, sizeHintLimits(drag.window), break_aspect),
        .tiled_split => unreachable, // returned above
    };
    drag.pending_rect = rect;

    // Throttle commits: resize is capped at the client repaint budget (see
    // max_resize_commit_hz) -- clients repaint on every size we send, and a
    // high-Hz panel must not turn a drag into an impossible repaint storm.
    // Moves are server-side copies and keep the full refresh rate. Still
    // track latest position for responsiveness. If a mode switch happens
    // mid-drag, we adapt live.
    const rate: f64 = switch (drag.mode) {
        .move => hz.detectedHz(),
        .resize => @min(hz.detectedHz(), max_resize_commit_hz),
        .tiled_split => unreachable, // returned above
    };
    const now = core.monotonicNs();
    const period_ns: u64 = commitPeriodNs(rate);
    if (now - drag.last_commit_ns >= period_ns) {
        if (drag.pending_rect) |r| {
            // Drop same-size commits (sub-pixel jiggle): a re-send of the
            // committed rect only costs the client a pointless repaint.
            const same = if (drag.last_committed) |last| std.meta.eql(last, r) else false;
            if (!same) {
                drag.last_commit_ns = now;
                drag.last_committed = r;
                dragRect(drag.window, r);
            }
            drag.pending_rect = null;
        }
    }
}

/// Ends the active drag. Flush any pending commit so the final position is
/// applied before releasing the drag state.
pub fn stopDrag() void {
    if (g_state.drag.active) {
        const drag = &g_state.drag;
        if (drag.pending_rect) |r| {
            const same = if (drag.last_committed) |last| std.meta.eql(last, r) else false;
            if (!same) dragRect(drag.window, r);
            drag.pending_rect = null;
        }
    }
    g_state = .{};
}

/// Clears the active drag if it targets `win`, without saving geometry. Used
/// when the dragged window is destroyed mid-drag; a lost ButtonRelease would
/// otherwise leave the drag stuck until the WM restarts, and there's no
/// geometry to persist for a dead window.
pub fn cancelDragForWindow(win: u32) void {
    if (g_state.drag.active and g_state.drag.window == win) g_state = .{};
}

pub fn isDragging() bool {
    return g_state.drag.active;
}

/// True when a resize drag is active on `win`; used to deny configure
/// requests from the window being resized, preventing flicker.
pub fn isResizingWindow(win: u32) bool {
    return g_state.drag.active and g_state.drag.mode == .resize and g_state.drag.window == win;
}

/// Updates a floating window's rect on the model, no-op for tiled/unknown.
pub fn setFloatingRect(m: *model.Model, win: model.WindowId, r: model.Rect) void {
    const e = m.store.getPtr(win) orelse return;
    if (e.presence == .covering) return; // fullscreen owns geometry
    if (e.anchor == .floating) e.anchor.floating = r;
}

/// Honors a configure request against a floating window record on the model.
pub fn honorConfigureRequest(
    m: *model.Model,
    win: model.WindowId,
    req: model.ConfigureReq,
) model.HonorDecision {
    if (registry.hide.callHookBool(.isWindowHidden, .{ m, win })) return .ignored;
    const e = m.store.getPtr(win) orelse return .ignored;
    if (e.presence == .covering) return .ignored; // fullscreen owns geometry
    switch (e.anchor) {
        .floating => |*r| {
            if (req.x) |v| r.x = v;
            if (req.y) |v| r.y = v;
            // A configure request is untrusted client input: clamp its extent
            // with the same envelope the drag path uses (sizeEnvelope). The
            // core half (border width, global min) only exists once core is
            // up; a headless model test exercises the PMin/PMax half without
            // one, so both pass 0 there.
            var bw2: i32 = 0;
            var min_dim: i32 = 0;
            if (core.isReady()) {
                bw2 = @as(i32, core.borderWidth()) * 2;
                min_dim = if (comptime build_options.has_tiling)
                    core.getState().config.tiling.min_window_dim
                else
                    types.default_min_window_dim;
            }
            const limits = sizeEnvelope(e.size_hints, bw2, min_dim);
            if (req.width) |v|
                r.width = @intCast(std.math.clamp(@as(i32, v), limits.min_w, @max(limits.min_w, limits.max_w)));
            if (req.height) |v|
                r.height = @intCast(std.math.clamp(@as(i32, v), limits.min_h, @max(limits.min_h, limits.max_h)));
            // Aspect band (ratio-accurate, same shared fit the drag path
            // uses): only when the request actually carries a size -- a
            // position-only configure must NOT re-lock a rect the user freed
            // with Shift.
            if (req.width != null or req.height != null) {
                const fit = e.size_hints.aspectFit(r.width, r.height);
                r.width = fit.width;
                r.height = fit.height;
            }
            // NOTE: a requested border_width is not stored here (the
            // floating rect has no bw field); the entry point sends and
            // caches it alongside the geometry it applies.
            return .geometry_applied;
        },
        .tiled => return if (req.border_width != null) .border_only else .ignored, // Geometry denied; BW honored, recording is SYNC's job
    }
}

/// This module's window sub-system contribution: the floating drag/resize
/// commands floating owns.
/// tiling<->floating command: lives beside the drag/rect state it transitions
/// against.
/// toggle_floating_window. Tiled->floating seeds the rect from the window's
/// current on-screen geometry (LastSent); floating->tiled re-enters the home
/// list at the primary-column head via the ordinary tiling order.
pub fn toggleFloating(win: model.WindowId) void {
    const m = pipeline.mut();
    const e = m.store.getPtr(win) orelse return;
    // A window carrying a covering record keeps its anchor: the record owns
    // the screen while covering, and a ghost (parked) record must survive
    // the command so the later toggle-off restores the ORIGINAL anchor, not
    // a flipped one.
    if (model.isCovering(m, win)) return;
    switch (e.anchor) {
        .tiled => {
            const r = reconcile.lastRectFor(win) orelse return;
            model.detachTiledToFloating(m, e, win, r);
        },
        .floating => |r| {
            e.anchor = .tiled;
            if (!repairStrandedHome(m, e, win)) {
                // The destination tiled list was full, so the window could not
                // be re-seated: keep it floating with its original rect rather
                // than leaving it anchored-tiled with no seat.
                e.anchor = .{ .floating = r };
                return;
            }
        },
    }
    reconcile_tails.retile(.{ .mode = .restack }, null);
}

/// Defense in depth (the stranded-slot bug class): repair a tiled-anchored
/// window that has no home-list entry instead of leaving it a
/// tiling-invisible window this toggle could never fix again.
fn repairStrandedHome(m: *model.Model, e: *model.Entry, win: model.WindowId) bool {
    if (model.findHome(m, win) != null) return true;
    if (model.lowestBit(e.mask)) |h| {
        // Append fails when the destination tiled list is full; only commit
        // home_ws when the seat actually got an entry, and report failure so
        // the caller can revert the anchor. Committing home_ws anyway would
        // leave the window anchored-tiled with no seat -- the exact stranded
        // state this function exists to prevent.
        if (!m.ws[h.index].tiled_order.append(win)) return false;
        e.home_ws = h;
    }
    return true;
}

pub const module: @import("window_contract").WindowModule = .{
    .name = "floating",
    .init = init,
    .deinit = deinit,
    .drag = .{
        .startDrag = startDrag,
        .stopDrag = stopDrag,
        .updateDrag = updateDrag,
        .isDragging = isDragging,
        .isResizingWindow = isResizingWindow,
        .cancelDragForWindow = cancelDragForWindow,
    },
    .floating = .{
        .setFloatingRect = setFloatingRect,
        .honorConfigureRequest = honorConfigureRequest,
    },
    .command = .{
        .toggleFloatingWindow = toggleFloating,
    },
};
