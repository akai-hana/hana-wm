//! Complete fullscreen feature: state transitions + read helpers + protocol hooks.
//! A self-contained plugin over the model: fullscreen state lives in THIS
//! module's OWN static store (g_recs), and the model only ever sees the generic
//! `.covering` presence pattern (or `.parked` while minimized). The module owns
//! the record (toggle + ws/anchor queries), the persistence seam
//! (serialize/deserialize), the coverage seam consumed by sync (`coverageOn`),
//! record cleanup for torn-down windows (`onWindowGone`), and the
//! protocol-side EWMH `_NET_WM_STATE_FULLSCREEN` advertisement plus the
//! deferred bar hide/show. The core never names fullscreen.
//!
//! A fullscreen record is a *ghost* while its window is minimized: minimize
//! parks the model entry (`presence == .parked`) but does NOT touch the rec,
//! so `fullscreenWsOf` still reports the ws and the rec resumes coverage on
//! restore.
//!
//! The deserialize hook receives the wire layer's `*model.Model` as a
//! `*anyopaque` (see plugin.WindowModule) so the seam's signature stays free
//! of model types in the core interface file (layer rule); the cast happens
//! here, where the concrete model type is known.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const utils = @import("utils");
const model = @import("model");
const build_options = @import("build_options");

/// One fullscreen window's record. `anchor` is the *pre-fullscreen* base mode
/// (the geometry/placement the window returns to on exit). `ws` is the
/// workspace whose screen the window owns while covering.
const Rec = struct { win: model.WindowId, ws: model.WSId, anchor: model.BaseMode };

/// Capacity ceiling for the fullscreen store, sourced from the model's store
/// capacity (no more fullscreen windows than windows): allocation-free,
/// linear scans, deterministic.
const MAX_FULLSCREEN = model.store_capacity;

/// Self-contained fullscreen store: static, allocation-free, linear scans.
/// No model bookkeeping backs it (the model only mirrors `.covering`).
var g_recs: utils.BoundedList(Rec, MAX_FULLSCREEN) = .{};

/// Window configured fullscreen but awaiting ConfigureNotify confirmation.
/// Zero when none pending. Set by armPendingBarHide; cleared in
/// notifyConfigureIfPending/resetState/onWindowGone.
var g_pending_bar_hide_win: u32 = 0;

/// Window that has exited fullscreen and been retiled but awaits ConfigureNotify
/// confirming its new dimensions. Zero when none pending. Set by
/// armPendingBarShow; cleared in notifyConfigureIfPending, resetState, onWindowGone.
var g_pending_bar_show_win: u32 = 0;

// EWMH atoms for _NET_WM_STATE_FULLSCREEN, resolved from the shared atom
// cache (utils.initAtomCache) in init(). Zero (XCB_ATOM_NONE) when the cache
// was unavailable; setEwmhFullscreenState's guard already skips the write then.
var g_net_wm_state: xcb.xcb_atom_t = 0;
var g_net_wm_state_fullscreen: xcb.xcb_atom_t = 0;

// Shared reset sequence used by both init() and deinit() to keep them in sync.
fn resetState() void {
    g_recs.clear();
    g_pending_bar_hide_win = 0;
    g_pending_bar_show_win = 0;
    g_net_wm_state = 0;
    g_net_wm_state_fullscreen = 0;
}

pub fn init() anyerror!void {
    resetState();

    // Re-resolve the EWMH fullscreen atoms from the shared atom cache rather
    // than interning them again here.
    g_net_wm_state = utils.getAtomOrZero("_NET_WM_STATE");
    g_net_wm_state_fullscreen = utils.getAtomOrZero("_NET_WM_STATE_FULLSCREEN");
}

pub fn deinit() void {
    resetState();
}

fn findRec(win: model.WindowId) ?usize {
    return g_recs.indexOfByIdField(.win, win);
}

/// Toggle `win`'s fullscreen capture of the current workspace.
///
/// ON (no existing rec): records `{ win, ws = m.current, anchor = <<deep copy
/// of e.anchor>> }` and sets `e.presence = .covering`. `anchor` is copied by
/// value (BaseMode is a value union; Rect copies cleanly) so the model keeps
/// its current anchor while the module remembers the pre-fullscreen one.
/// OFF (rec exists): drops the rec and sets `e.presence = .present`.
///
/// Returns true iff a transition happened (turn on OR turn off). Returns false
/// when the entry is missing, when the window is currently minimized (gated
/// feature->feature guard), or when the store is full (capacity check runs
/// BEFORE any mutation, so a full store refuses the toggle without side
/// effects).
pub fn toggleFullscreen(m: *model.Model, win: model.WindowId) bool {
    if (build_options.has_minimize) {
        // Defensive feature->feature guard (the wire already pre-guards):
        // keep it here so the module is safe standalone. Idempotent with the
        // wire guard.
        if (@import("minimize").isMinimized(m, win)) return false;
    }
    const e = m.store.getPtr(win) orelse return false;
    if (findRec(win) != null) {
        // OFF: leave fullscreen; restore the pre-fullscreen anchor to the model.
        _ = g_recs.orderedRemove(findRec(win).?);
        e.presence = .present;
        e.covering_ws = null; // release the core covering intent
        return true;
    }
    // ON: capacity guard BEFORE any mutation — a full store refuses the
    // toggle (returns false, model untouched).
    if (g_recs.len >= MAX_FULLSCREEN) return false;
    const anchor = switch (e.anchor) {
        .tiled => model.BaseMode.tiled,
        .floating => |r| model.BaseMode{ .floating = r },
    };
    _ = g_recs.append(.{ .win = win, .ws = m.current, .anchor = anchor });
    e.presence = .covering;
    e.covering_ws = m.current; // model stays the authority on the capture target
    return true;
}

/// True when `win` holds a covering (fullscreen) capture, derived from the
/// MODEL's core `covering_ws` intent (the module's `g_recs` is kept in
/// lockstep but the model is the single authoritative reader). Reports true
/// even while the model presence is parked — a minimized-from-fullscreen
/// window keeps `covering_ws` set — so the ghost state (the record survives
/// while hidden) is preserved. Reading the model here keeps this predicate
/// consistent with `fullscreenWsOf` and the core `coveringOccupantOnWs`,
/// avoiding a split authority where the module and model disagree.
pub fn isFullscreenMode(m: *const model.Model, win: model.WindowId) bool {
    const e = m.store.get(win) orelse return false;
    return e.covering_ws != null;
}

/// The workspace `win`'s covering capture anchors to, per the MODEL's core
/// `covering_ws` intent (the module's `g_recs[].ws` is kept in lockstep with
/// it, but the model is the single authoritative reader). GHOST: still reports
/// the ws even while the model presence is parked (minimized-from-fullscreen:
/// minimize leaves `covering_ws` set), so callers classifying drops/withdraw-
/// without-destroy can read the true target before teardown.
pub fn fullscreenWsOf(m: *const model.Model, win: model.WindowId) ?model.WSId {
    const e = m.store.get(win) orelse return null;
    return e.covering_ws;
}

/// Whether `win` has a fullscreen record targeting `ws`. Unlike
/// fullscreenOccupantOnWs this does NOT consult visibility; callers use it for
/// pre-toggle classification and was-fullscreen captures.
pub fn isFullscreenOnWs(m: *const model.Model, win: model.WindowId, ws: model.WSId) bool {
    _ = m;
    const idx = findRec(win) orelse return false;
    return g_recs.slice()[idx].ws == ws;
}

/// The first record on `ws` whose window exists, is present-not-parked AND
/// visible on `ws` (a stray record targeting `ws` whose base is tagged
/// elsewhere never counts as an occupant -- sync parks such strays instead of
/// letting them claim the slot). Ghost records whose window is parked
/// (minimized) return null -- the slot looks free to the bar even though the
/// rec still exists on-disk. At most one
/// visible fullscreen per ws is guaranteed by sync (others parked).
pub fn fullscreenOccupantOnWs(m: *const model.Model, ws: model.WSId) ?model.WindowId {
    for (g_recs.constSlice()) |rec| {
        if (rec.ws != ws) continue;
        const e = m.store.get(rec.win) orelse continue;
        if (e.presence == .parked) continue;
        if (!model.visibleOn(m, rec.win, ws)) continue;
        return rec.win;
    }
    return null;
}

/// True iff some OTHER window's record covers `dest`: a rec with `r.win != win`,
/// `r.ws == dest`, whose window is present-not-parked AND visible on `dest`
/// (same visibility rule as the occupant query). Shared with the workspaces
/// move/tag slice: fullscreen transfer-on-move drops the mover rather than
/// clobbering a resident.
pub fn fullscreenOccupied(m: *const model.Model, win: model.WindowId, dest: model.WSId) bool {
    for (g_recs.constSlice()) |rec| {
        if (rec.win == win) continue;
        if (rec.ws != dest) continue;
        const e = m.store.get(rec.win) orelse continue;
        if (e.presence == .parked) continue;
        if (!model.visibleOn(m, rec.win, dest)) continue;
        return true;
    }
    return false;
}

/// Seam for the workspaces module's move/tag slice: retargets `win`'s record
/// to `ws`. This now SYNCS the model's core `covering_ws` intent alongside the
/// module record (a covering window stays covering; a ghost record of a
/// minimized window follows the mask) so the model stays the single authority
/// on the capture target and the module never diverges from it. The caller has
/// already confirmed the destination is not occupied.
pub fn moveFullscreenTo(m: *const model.Model, win: model.WindowId, ws: model.WSId) void {
    const idx = findRec(win) orelse return;
    const eptr = @constCast(m).store.getPtr(win) orelse return;
    g_recs.slice()[idx].ws = ws;
    eptr.covering_ws = ws;
}

/// The coverage seam body (plugin.WindowModule.coverageOn) consumed by sync's
/// reconcile: the first record whose store entry exists, is present-not-parked,
/// and either targets `ws` directly or is visible on `ws`. This is a faithful
/// migration of the Tier-1 sync fs-scan into the module: sync asks once per
/// reconcile and parks everyone else while a covering winner holds the screen.
pub fn coverageOn(m: *const model.Model, ws: model.WSId) ?model.WindowId {
    for (g_recs.constSlice()) |rec| {
        const e = m.store.get(rec.win) orelse continue;
        if (e.presence == .parked) continue;
        if (rec.ws == ws or model.visibleOn(m, rec.win, ws)) return rec.win;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Persistence seam. Blob byte layout (self-identifying, < 32 bytes):
//     [0]      = 0x46 ('F')         magic / format tag
//     [1]      = ws : u8            fullscreen workspace id (WSId is u16 but
//                                   real ws ids are < 256 in practice)
//     [2]      = anchor tag : u8    { 1 = tiled, 2 = floating }
//     if floating (tag == 2), the anchor's rect follows as native little-endian:
//     [3..7]   = x  : u32 (sign-preserving: Rect.x i16 bit-cast to i32 then u32)
//     [7..11]  = y  : u32 (same sign-preserving treatment)
//     [11..13] = width        : u16
//     [13..15] = height       : u16
//     [15..17] = border_width : u16
//     total: 3 bytes for tiled, 17 bytes for floating.
// ---------------------------------------------------------------------------

const FS_MAGIC: u8 = 0x46;
const TAG_TILED: u8 = 1;
const TAG_FLOATING: u8 = 2;
const BLOB_LEN_TILED: usize = 3;
const BLOB_LEN_FLOATING: usize = 17;

// Native-little-endian slot writes/reads at an offset. Width comes from the
// comptime `T`, so one helper each covers the u16/u32 fields in the blob.
fn writeLE(comptime T: type, buf: []u8, off: usize, v: T) void {
    std.mem.writeInt(T, buf[off..][0..@sizeOf(T)], v, .little);
}

fn readLE(comptime T: type, bytes: []const u8, off: usize) T {
    return std.mem.readInt(T, bytes[off..][0..@sizeOf(T)], .little);
}

/// Persistence seam (plugin.WindowModule.serializeWindow): marshals this
/// window's fullscreen record as an opaque blob (layout above). Returns a blob
/// ONLY when the window has a fullscreen rec AND its model presence is NOT
/// parked. When the window is parked (minimized), the fullscreen rec is a
/// ghost and the single `ext` slot belongs to minimize — return null so the
/// minimized blob wins (design §6). The returned slice is allocator-owned;
/// persist frees it after writing.
pub fn serializeWindow(model_ptr: *anyopaque, win: u32, alloc: std.mem.Allocator) ?[]const u8 {
    const m: *const model.Model = @ptrCast(@alignCast(model_ptr));
    const idx = findRec(win) orelse return null;
    const rec = g_recs.slice()[idx];
    const e = m.store.get(win) orelse return null;
    if (e.presence == .parked) return null; // parked window: minimize owns the blob
    const len: usize = switch (rec.anchor) {
        .tiled => BLOB_LEN_TILED,
        .floating => BLOB_LEN_FLOATING,
    };
    const buf = alloc.alloc(u8, len) catch return null;
    buf[0] = FS_MAGIC;
    buf[1] = @intCast(rec.ws);
    switch (rec.anchor) {
        .tiled => {
            buf[2] = TAG_TILED;
        },
        .floating => |r| {
            buf[2] = TAG_FLOATING;
            // Sign-preserving: i16 -> i32 -> u32, so decode via @truncate to i16.
            writeLE(u32, buf, 3, @as(u32, @bitCast(@as(i32, r.x))));
            writeLE(u32, buf, 7, @as(u32, @bitCast(@as(i32, r.y))));
            writeLE(u16, buf, 11, r.width);
            writeLE(u16, buf, 13, r.height);
            writeLE(u16, buf, 15, r.border_width);
        },
    }
    return buf;
}

/// Persistence seam (plugin.WindowModule.deserializeWindow): adopts the blob
/// written by `serializeWindow` and replays the covering record on the live
/// model (passed in as `*anyopaque`). Returns true when this module claims the
/// blob; false (magic mismatch, unknown window, wrong length) lets the
/// registry loop continue to other modules. Idempotent when the rec already
/// exists.
pub fn deserializeWindow(win: u32, bytes: []const u8, ptr: *anyopaque) bool {
    if (bytes.len < 1 or bytes[0] != FS_MAGIC) return false; // not ours
    if (findRec(win) != null) return true; // already adopted; idempotent
    const m: *model.Model = @ptrCast(@alignCast(ptr));
    const e = m.store.getPtr(win) orelse return false;
    if (bytes.len < 3) return false;
    const ws: model.WSId = @intCast(bytes[1]);
    const tag = bytes[2];
    var anchor: model.BaseMode = undefined;
    switch (tag) {
        TAG_TILED => {
            if (bytes.len != BLOB_LEN_TILED) return false;
            anchor = .tiled;
        },
        TAG_FLOATING => {
            if (bytes.len != BLOB_LEN_FLOATING) return false;
            const rect = utils.Rect{
                .x = @as(i16, @truncate(@as(i32, @bitCast(readLE(u32, bytes, 3))))),
                .y = @as(i16, @truncate(@as(i32, @bitCast(readLE(u32, bytes, 7))))),
                .width = readLE(u16, bytes, 11),
                .height = readLE(u16, bytes, 13),
                .border_width = readLE(u16, bytes, 15),
            };
            anchor = .{ .floating = rect };
            // The blob restores the pre-fullscreen floating rect: the model
            // only persisted the *current* anchor, so we replace it with the
            // saved one (restores fullscreen.base semantics of Tier 1).
            e.anchor = .{ .floating = rect };
        },
        else => return false,
    }
    // This hook is only dispatched for non-parked windows (fullscreen blob
    // only exists for non-parked), so we can safely mark the window covering.
    if (g_recs.len >= MAX_FULLSCREEN) return false;
    _ = g_recs.append(.{ .win = win, .ws = ws, .anchor = anchor });
    e.presence = .covering;
    e.covering_ws = ws; // sync the model's core covering intent with the record
    return true;
}

// ---------------------------------------------------------------------------
// Protocol hooks (EWMH advertisement + deferred bar hide/show).
// ---------------------------------------------------------------------------

// Sets or clears the EWMH _NET_WM_STATE_FULLSCREEN property on `win`. The
// actual change_property write is routed through sync's sink (the ONLY writer
// to X); the EWMH atoms stay resolved here and the write is queued inside the
// enclosing grab (reconcileUnderGrabNowFullscreen), whose ungrabAndFlush lands
// it atomically with geometry. Guards on both EWMH atoms being valid; pub for
// actions.fullscreenToggleWindow, keeping the advertisement protocol-side.
pub fn setEwmhFullscreenState(win: u32, is_fullscreen: bool) void {
    if (g_net_wm_state == xcb.XCB_ATOM_NONE or
        g_net_wm_state_fullscreen == xcb.XCB_ATOM_NONE) return;
    @import("sync").setEwmhFullscreen(
        @import("pipeline").grabCtx(),
        win,
        g_net_wm_state,
        g_net_wm_state_fullscreen,
        is_fullscreen,
    );
}

// The protocol-side geometry commit helpers are gone: sync.reconcile derives
// their wire traffic from the model.

/// Called from the ConfigureNotify handler in events.zig. Drives both deferred
/// bar transitions: hide on confirmed fullscreen dimensions (enter), show on
/// non-fullscreen ones (exit). Safe for every ConfigureNotify; no-ops when
/// nothing is pending or dimensions don't match.
pub fn notifyConfigureIfPending(win: u32, width: u16, height: u16) void {
    const cs = core.getState();
    const screen_w = @as(u16, @intCast(cs.screen.width_in_pixels));
    const screen_h = @as(u16, @intCast(cs.screen.height_in_pixels));

    // Deferred bar hide (enter-fullscreen path): window must report exactly
    // screen dimensions before we hide the bar. Deferred bar show (exit
    // path) must report non-fullscreen dimensions first. The else-if makes
    // the mutual exclusion explicit: both can never match for the same win.
    // In both cases we only bump core's fullscreen-occupancy fact; the bar
    // (a consumer) derives its own hide/show from that fact.
    if (g_pending_bar_hide_win == win) {
        if (width == screen_w and height == screen_h) {
            g_pending_bar_hide_win = 0;
            @import("core").bumpFullscreen();
        }
    } else if (g_pending_bar_show_win == win) {
        if (width != screen_w or height != screen_h) {
            resolvePendingBarShow();
        }
    }
}

fn resolvePendingBarShow() void {
    g_pending_bar_show_win = 0;
    @import("core").bumpFullscreen();
}

/// Arm the deferred bar-hide from the fullscreenToggle path.
pub fn armPendingBarHide(win: u32) void {
    g_pending_bar_show_win = 0;
    g_pending_bar_hide_win = win;
}

/// Arm the deferred bar-show after an exit reconcile (armed AFTER geometry
/// settles).
pub fn armPendingBarShow(win: u32) void {
    g_pending_bar_hide_win = 0;
    g_pending_bar_show_win = win;
}

/// Record cleanup on window teardown; the wire layer fires this (events /
/// unmanage) after removing the store entry. Also clears any pending deferred
/// bar op so the bar doesn't stay stuck (both show and hide cases).
pub fn onWindowGone(win: u32) void {
    if (findRec(win)) |i| _ = g_recs.orderedRemove(i);
    if (g_pending_bar_show_win == win) resolvePendingBarShow();
    if (g_pending_bar_hide_win == win) g_pending_bar_hide_win = 0;
}

/// This module's window sub-system contribution: lifecycle + persistence +
/// coverage seam + record cleanup + the EWMH/bar protocol hooks.
pub const module: @import("plugin").WindowModule = .{
    .init = init,
    .deinit = deinit,
    .notifyConfigureIfPending = notifyConfigureIfPending,
    .onWindowGone = onWindowGone,
    .serializeWindow = serializeWindow,
    .deserializeWindow = deserializeWindow,
    .setEwmhFullscreenState = setEwmhFullscreenState,
    .armPendingBarHide = armPendingBarHide,
    .armPendingBarShow = armPendingBarShow,
    .coverageOn = coverageOn,
    .toggleCovering = toggleFullscreen,
    .isCoveringMode = isFullscreenMode,
    .coveringWsOf = fullscreenWsOf,
    .isCoveringOnWs = isFullscreenOnWs,
    .coveringOccupantOnWs = fullscreenOccupantOnWs,
};
