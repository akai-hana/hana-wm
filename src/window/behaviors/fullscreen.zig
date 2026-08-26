//! Fullscreen protocol-side residue.
//!
//! Fullscreen TRUTH lives in the model (`Entry.mode == .fullscreen`);
//! query it through model.isFullscreenMode / model.fullscreenOccupantOnWs.
//! This module owns only what is genuinely protocol-side:
//!   - deferred bar hide/show armed around a fullscreen transition and
//!     resolved on ConfigureNotify confirmation,
//!   - EWMH _NET_WM_STATE_FULLSCREEN advertisement.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const utils = @import("utils");

const build_options = @import("build_options");
const bar = if (build_options.has_bar) @import("bar") else null;

/// Window configured fullscreen but awaiting ConfigureNotify confirmation.
/// Zero when none pending. Set in enterFullscreenCommit; cleared in
/// notifyConfigureIfPending/resetState.
var g_pending_bar_hide_win: u32 = 0;

/// Window that has exited fullscreen and been retiled but awaits ConfigureNotify
/// confirming its new dimensions. Zero when none pending. Set in exitFullscreen
/// after retile; cleared in notifyConfigureIfPending, resetState, onWindowGone.
var g_pending_bar_show_win: u32 = 0;

// EWMH atoms for _NET_WM_STATE_FULLSCREEN, resolved from the shared atom
// cache (utils.initAtomCache) in init(). Zero (XCB_ATOM_NONE) when the cache
// was unavailable; setEwmhFullscreenState's guard already skips the write then.
var g_net_wm_state: xcb.xcb_atom_t = 0;
var g_net_wm_state_fullscreen: xcb.xcb_atom_t = 0;

// Shared reset sequence used by both init() and deinit() to keep them in sync.
fn resetState() void {
    g_pending_bar_hide_win = 0;
    g_pending_bar_show_win = 0;
    g_net_wm_state = 0;
    g_net_wm_state_fullscreen = 0;
}

pub fn init() void {
    resetState();

    // Re-resolve the EWMH fullscreen atoms from the shared atom cache rather
    // than interning them again here.
    g_net_wm_state = utils.getAtomOrZero("_NET_WM_STATE");
    g_net_wm_state_fullscreen = utils.getAtomOrZero("_NET_WM_STATE_FULLSCREEN");
}

pub fn deinit() void {
    resetState();
}

// Set or clear the EWMH _NET_WM_STATE_FULLSCREEN property on `win`.
// Guards on both atoms being valid before touching the property.
// Pub for actions.fullscreenToggle — EWMH advertisement stays
// protocol-side.
pub fn setEwmhFullscreenState(win: u32, is_fullscreen: bool) void {
    if (g_net_wm_state == xcb.XCB_ATOM_NONE or
        g_net_wm_state_fullscreen == xcb.XCB_ATOM_NONE) return;
    const count: u32 = if (is_fullscreen) 1 else 0;
    _ = xcb.xcb_change_property(
        core.getState().conn,
        xcb.XCB_PROP_MODE_REPLACE,
        win,
        g_net_wm_state,
        xcb.XCB_ATOM_ATOM,
        32,
        count,
        if (is_fullscreen) &g_net_wm_state_fullscreen else null,
    );
}

// The legacy commit helpers (enterFullscreenCommit / exitFullscreenCommit /
// applyFullscreenGeometry) are deleted — sync.reconcile derives their wire
// traffic from the model.

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
    if (g_pending_bar_hide_win == win) {
        if (width == screen_w and height == screen_h) {
            g_pending_bar_hide_win = 0;
            if (build_options.has_bar) bar.setBarState(.hide_fullscreen);
        }
    } else if (g_pending_bar_show_win == win) {
        if (width != screen_w or height != screen_h) {
            resolvePendingBarShow();
        }
    }
}

fn resolvePendingBarShow() void {
    g_pending_bar_show_win = 0;
    if (build_options.has_bar) bar.setBarState(.show_fullscreen);
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

/// Called when a window is destroyed; clears its pending deferred bar op so
/// the bar doesn't stay stuck. Both cases need it: show (window dies
/// between exit and its ConfigureNotify) AND hide (window dies between
/// armPendingBarHide and its ConfigureNotify — nothing else would ever
/// resolve the hide, leaving the bar hidden for good).
pub fn onWindowGone(win: u32) void {
    if (g_pending_bar_show_win == win) resolvePendingBarShow();
    if (g_pending_bar_hide_win == win) g_pending_bar_hide_win = 0;
}
