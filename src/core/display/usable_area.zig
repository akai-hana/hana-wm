//! The usable-screen-area fact.
//!
//! Core owns "how much of the screen is left for window placement after all
//! surfaces that occupy screen space are accounted for." Any such surface (a
//! bar, a dock, a future taskbar) contributes "the claim": an edge plus how
//! many pixels it takes from that edge, released when it stops occupying
//! space. One slot today (see `claim`); the ledger grows slots only when a
//! second claimant exists. Core computes `workArea()` from the active claim
//! and the physical screen dimensions.
//!
//! Surfaces push claims and read nothing back beyond `workArea()`. They never
//! hand core a final number; the subtraction math is core's, so the fact
//! lives here, not in any particular surface. With no active claims, the
//! usable area is the full screen (the natural state when the bar is absent).
//!
//! ## "Fullscreen means no work area" is NOT this module's rule (6.10)
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
    /// Which monitor the claim is held on.
    ///
    /// A claim is a statement about a SCREEN, not about the process, so it
    /// has to name its screen: on a multi-monitor setup a claim must not
    /// shrink another monitor's usable area. Today there is exactly one
    /// screen and exactly one claim (see `claim`), so the default is the only
    /// correct answer and nothing reads the field -- but the alternative was
    /// a claim whose subject was implicit, which is precisely the assumption
    /// that breaks the moment a second monitor appears.
    monitor: u8 = 0,
    edge: Edge = .top,
    px: u16 = 0,
};

/// The one active claim, absent when nothing occupies screen space.
///
/// A single optional, not a table: today exactly one surface (the bar) claims
/// screen space, so the `[max_claims]`-slots-plus-comptime-ids ledger was a
/// table of exactly 1 (the KISS audit's ?Claim collapse). A second claimant
/// reintroduces slots AND per-claimant keying then -- `mappedSurfaceWindow`
/// must key off its OWN claimant's claim, never "any claim", the day two
/// coexist. `px == 0` is encoded as absence (null), not an inactive entry:
/// every reader (insets, mapped-surface) skips both encodings identically.
var claim: ?Claim = null;

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
/// "The claimant holds the claim" == "the surface window is claimed" only
/// while there is ONE slot: the optional IS the bar's claim today. The day a
/// second slot exists, key this off that surface's OWN claim, never "any
/// claim is active" -- a dock alone claiming screen space must not make the
/// caller stack-raise a bar that is not on screen (the note the [max_claims]
/// table used to carry here).
pub fn mappedSurfaceWindow() ?core.WindowId {
    if (claim == null) return null;
    return surface_win;
}

/// Sets (or re-sets) the claim. `px == 0` releases it (null), the same
/// observable state the old inactive table entry had. Calling this with a
/// changed edge or pixel count replaces the previous claim; the caller is
/// responsible for triggering any reconcile that new geometry requires.
/// No id parameter: with one slot there is nothing to address (the old
/// comptime-id bounds check was the table-of-1's scaffolding -- a no-op
/// ReleaseFast assert could never be its replacement).
pub fn setClaim(edge: Edge, px: u16) void {
    claim = if (px == 0) null else .{ .edge = edge, .px = px };
}

/// Releases the claim, returning usable area to full screen.
pub fn releaseClaim() void {
    claim = null;
}

/// Pixels the active claim takes from each edge (indexed by
/// @intFromEnum(Edge)); zeroed edges when nothing claims. Pure over the one
/// slot, so the arithmetic the usable-area depends on is testable without an
/// X connection. `+=` keeps the sum reading (a second slot lands here as
/// another addend without touching the math).
fn claimInsets() [4]u32 {
    // Index by @intFromEnum so the reading order below and the field order of
    // the Edge enum have one definition between them. Writing the four
    // cases out spelled out the mapping twice, and the two copies could
    // disagree: a case reordering the enum would still have compiled.
    var insets = [4]u32{ 0, 0, 0, 0 };
    if (claim) |c| insets[@intFromEnum(c.edge)] += c.px;
    return insets;
}

/// The usable-area arithmetic, with no global state and no X handle.
///
/// Every subtraction SATURATES (`-|`) on purpose: an over-claiming surface
/// (two bars on one edge, or a claim wider than a small screen) must yield a
/// zero-sized area rather than wrapping to a huge one and handing the layouts
/// a rect off the end of the display. That behavior is load-bearing and was
/// previously only reachable through a live screen, which is why it now has
/// this seam.
///
/// A zero-sized result is a DEGENERATE CONFIGURATION, not a normal state and
/// not a fullscreen encoding: it is reachable only when the sum of claims on
/// an axis meets or exceeds the screen's extent along it (a bar taller than
/// the display). Consumers must treat it as "nowhere to place", which is the
/// honest answer, rather than as a signal about fullscreen. Reachable
/// non-degenerately: no claims at all, which yields the full screen.
pub fn workAreaFrom(screen_w: u32, screen_h: u32) model.Rect {
    const insets = claimInsets();
    return .{
        .x = @intCast(insets[2]),
        .y = @intCast(insets[0]),
        .width = @intCast(screen_w -| insets[2] -| insets[3]),
        .height = @intCast(screen_h -| insets[0] -| insets[1]),
    };
}

pub fn workArea(screen: core.Screen) model.Rect {
    return workAreaFrom(screen.width_in_pixels, screen.height_in_pixels);
}
