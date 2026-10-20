//! The usable-screen-area fact.
//!
//! Core owns "how much of the screen is left for window placement after all
//! surfaces that occupy screen space are accounted for." Any such surface (a
//! bar, a dock, a future taskbar) contributes "the claim": an edge plus how
//! many pixels it takes from that edge, released when it stops occupying
//! space. Core computes `workArea()` from the active claims and the physical
//! screen dimensions.
//!
//! There are two claimant CLASSES, and they stay separate on purpose:
//!
//!   - The chrome surface (the bar) holds the single `claim` slot. It is
//!     special: it registers its window at init (surface recognition,
//!     stacking, click routing) and answers "a fullscreen window wants the
//!     whole screen" by RELEASING its claim (see below).
//!   - Foreign docks (EWMH `_NET_WM_STRUT_PARTIAL`, parsed by the window
//!     layer's protocol/struts.zig) hold PER-WINDOW slots keyed by X id,
//!     so a property change or an unmanage replaces/releases exactly its
//!     own entry. D27's struts-only interim: one screen, the four edge
//!     widths summed per edge; no per-monitor geometry here.
//!
//! Surfaces push claims and read nothing back beyond `workArea()`. They never
//! hand core a final number; the subtraction math is core's, so the fact
//! lives here, not in any particular surface. With no active claims, the
//! usable area is the full screen (the natural state when the bar is absent
//! and no dock has claimed an edge).
//!
//! ## "Fullscreen means no work area" is NOT this module's rule
//!
//! The tempting encoding -- core reads `fullscreen_rev` and hands placement a
//! zero area while something is fullscreen -- is deliberately absent, and this
//! paragraph is the contract that keeps it absent. Occupancy is expressed one
//! way only: as claims. The bar already answers "a fullscreen window wants the
//! whole screen" by RELEASING its claim (`hideBarForFullscreen` ->
//! `applyVisibility` -> `publishClaim`), so the work area becomes the full
//! screen without anyone special-casing fullscreen. Two encodings of the same
//! fact would be one too many: they disagree the moment a second surface
//! claims an edge, and there is no total order between "released because
//! fullscreen" and "released because the bar is off" -- a bar that is both
//! hidden AND fullscreen-covered would have to pick which story to tell, and
//! the answer would depend on which module asked first.
//!
//! The remaining question this file does own is what a claim LARGER than the
//! screen means, and the answer is the saturating subtraction below: a
//! zero-sized rect, never a wrapped one. See `workAreaFrom`.

const core = @import("core");
const model = @import("model");

/// Which screen edge a claim occupies.
pub const Edge = enum { top, bottom, left, right };

const Claim = struct {
    edge: Edge = .top,
    px: u16 = 0,
};

/// The chrome surface's (bar's) active claim, absent when the bar is not
/// occupying screen space. This slot is the bar's ALONE: foreign docks live
/// in the per-window table below and never write here, so `mappedSurfaceWindow`
/// and the release-on-fullscreen protocol keep one story to tell.
var claim: ?Claim = null;

/// Per-window strut claims from foreign docks (EWMH `_NET_WM_STRUT_PARTIAL`).
/// Keyed by the dock's X id so a property change or unmanage replaces or
/// releases exactly its own entry; fixed capacity, allocation-free, like the
/// rest of the layer's tables. A desktop with more simultaneous external
/// docks than this is pathological; the overflow window keeps its geometry
/// but contributes no claim (honest degradation, not a crash or a wrap).
const max_dock_claims = 8;

pub const DockClaim = struct {
    win: core.WindowId = 0,
    left: u16 = 0,
    right: u16 = 0,
    top: u16 = 0,
    bottom: u16 = 0,
};

var dock_claims: [max_dock_claims]?DockClaim = .{null} ** max_dock_claims;

/// The X window id of the chrome surface (the bar), registered by that
/// surface at init/deinit. Lets core recognize "this window is chrome" (to
/// exclude it from management, route clicks to it) without core naming the
/// surface. Null when no surface is present.
var surface_win: ?core.WindowId = null;

/// Registers the chrome surface's X window id. Called once at surface init;
/// core can then answer window-recognition queries without naming the surface.
pub fn setSurfaceWindow(win: core.WindowId) void {
    surface_win = win;
}

/// Clears the registered chrome window. Called at surface deinit.
pub fn clearSurfaceWindow() void {
    surface_win = null;
}

/// The chrome surface's window id, if any.
pub fn surfaceWindow() ?core.WindowId {
    return surface_win;
}

/// True when `win` is the chrome surface's own window (bar). Used to exclude
/// it from window management / focus / drag handling.
pub fn isSurfaceWindow(win: core.WindowId) bool {
    return surface_win == win;
}

/// The chrome surface's window id when IT currently occupies screen space;
/// null otherwise. Used for raise-above stacking.
///
/// Keyed off the BAR's own claim slot, never off "any claim is active": a
/// dock's per-window claim does not make a hidden bar occupy screen space.
pub fn mappedSurfaceWindow() ?core.WindowId {
    if (claim == null) return null;
    return surface_win;
}

/// Sets (or re-sets) the claim. `px == 0` releases it (null). Calling this
/// with a changed edge or pixel count replaces the previous claim; the caller
/// is responsible for triggering any reconcile that new geometry requires.
/// No id parameter: with one slot there is nothing to address.
pub fn setClaim(edge: Edge, px: u16) void {
    claim = if (px == 0) null else .{ .edge = edge, .px = px };
}

/// Releases the claim, returning usable area to full screen.
pub fn releaseClaim() void {
    claim = null;
}

/// Sets (or re-sets) `win`'s dock strut claim. An all-zero insets set RELEASES
/// the entry (an EWMH client zeroing its strut stops occupying the edge); the
/// caller triggers any reconcile new geometry requires. Returns true when the
/// stored claim actually changed, so a property-notify refresh that re-reads
/// the same values does not force a re-tile.
pub fn setDockClaim(
    win: core.WindowId,
    left: u16,
    right: u16,
    top: u16,
    bottom: u16,
) bool {
    if (left == 0 and right == 0 and top == 0 and bottom == 0) return releaseDockClaim(win);
    for (&dock_claims) |*slot| {
        if (slot.*) |*c| {
            if (c.win != win) continue;
            const changed = c.left != left or c.right != right or c.top != top or c.bottom != bottom;
            c.* = .{ .win = win, .left = left, .right = right, .top = top, .bottom = bottom };
            return changed;
        }
    }
    for (&dock_claims) |*slot| {
        if (slot.* == null) {
            slot.* = .{ .win = win, .left = left, .right = right, .top = top, .bottom = bottom };
            return true;
        }
    }
    // Table full: the window contributes no claim (documented on max_dock_claims).
    return false;
}

/// Drops `win`'s dock claim (unmanage / strut withdrawn). True when a claim
/// was actually released.
pub fn releaseDockClaim(win: core.WindowId) bool {
    for (&dock_claims) |*slot| {
        if (slot.*) |c| if (c.win == win) {
            slot.* = null;
            return true;
        };
    }
    return false;
}

/// `win`'s current dock claim, if any. Pure read, for tests and diagnostics.
pub fn dockClaimOf(win: core.WindowId) ?DockClaim {
    for (dock_claims) |slot| {
        if (slot) |c| if (c.win == win) return c;
    }
    return null;
}

/// Pixels the active claims take from `edge`: the bar's slot plus every
/// foreign dock's, summed. Pure over the ledger, so the arithmetic the
/// usable-area depends on is testable without an X connection.
fn inset(edge: Edge) u32 {
    var total: u32 = 0;
    if (claim) |c| {
        if (c.edge == edge) total += c.px;
    }
    for (dock_claims) |slot| {
        if (slot) |d| switch (edge) {
            .top => total += d.top,
            .bottom => total += d.bottom,
            .left => total += d.left,
            .right => total += d.right,
        };
    }
    return total;
}

/// The usable-area arithmetic, with no global state and no X handle.
///
/// Every subtraction SATURATES (`-|`) on purpose: an over-claiming surface
/// (two bars on one edge, or a claim wider than a small screen) must yield a
/// zero-sized area rather than wrapping to a huge one and handing the layouts
/// a rect off the end of the display. That behavior is load-bearing, so the
/// arithmetic is exposed through this public, X-free entry.
///
/// A zero-sized result is a DEGENERATE CONFIGURATION, not a normal state and
/// not a fullscreen encoding: it is reachable only when the sum of claims on
/// an axis meets or exceeds the screen's extent along it (a bar taller than
/// the display). Consumers must treat it as "nowhere to place", which is the
/// honest answer, rather than as a signal about fullscreen. Reachable
/// non-degenerately: no claims at all, which yields the full screen.
pub fn workAreaFrom(screen_w: u32, screen_h: u32) model.Rect {
    const top = inset(.top);
    const bottom = inset(.bottom);
    const left = inset(.left);
    const right = inset(.right);
    return .{
        .x = @intCast(left),
        .y = @intCast(top),
        .width = @intCast(screen_w -| left -| right),
        .height = @intCast(screen_h -| top -| bottom),
    };
}

pub fn workArea(screen: core.Screen) model.Rect {
    return workAreaFrom(screen.width_in_pixels, screen.height_in_pixels);
}
