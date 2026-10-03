//! The usable-screen-area fact.
//!
//! Core owns "how much of the screen is left for window placement after all
//! surfaces that occupy screen space are accounted for." Any such surface (a
//! bar, a dock, a future taskbar) contributes a "claim": an edge plus how
//! many pixels it takes from that edge, released when it stops occupying
//! space. Core computes `workArea()` from the set of active claims and the
//! physical screen dimensions.
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
const build_options = @import("build_options");
const model = @import("model");

/// Which screen edge a claim occupies.
pub const Edge = enum { top, bottom, left, right };

const Claim = struct {
    /// Which monitor the claim is held on.
    ///
    /// A claim is a statement about a SCREEN, not about the process, so it
    /// has to name its screen: on a multi-monitor setup two surfaces can hold
    /// claims simultaneously on different monitors, and the usable area of
    /// monitor 0 must not be shrunk by monitor 1's bar. Today there is exactly
    /// one screen, so the default is the only correct answer and nothing
    /// reads the field -- but the alternative was a claim whose subject was
    /// implicit in the table it happened to sit in, which is precisely the
    /// assumption that breaks the moment a second monitor appears.
    monitor: u8 = 0,
    edge: Edge = .top,
    px: u16 = 0,
    active: bool = false,
};

// Compile-time number of claim slots. Each surface that exists in a given
// build owns one slot, addressed by a comptime id. Today only the bar claims
// screen space; a future surface adds its own slot here (and its own id
// constant), keeping the ledger fully comptime-sized (no allocation, no
// runtime registration).
const max_claims = if (build_options.has_bar) 1 else 0;

// The bar is surface id 0 (present only when has_bar). With no bar compiled
// in there are no claim ids at all, so the constant must not exist: a caller
// that reads it is already broken and should fail at compile time rather than
// index a zero-length array.
pub const bar_id: u8 = if (build_options.has_bar) 0 else unreachable;

var claims: [max_claims]Claim = [_]Claim{.{}} ** max_claims;

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
/// Keyed off the bar's own claim, not "any active claim". Those coincide only
/// because `max_claims` is 1: the loop it replaced returned `surface_win` --
/// unconditionally the BAR's window -- as soon as ANY claim was active, so
/// the day a dock or taskbar adds the second slot, a dock alone claiming
/// screen space would have the caller stack-raise a bar that is not on screen.
/// The coincidence is now written down instead of relied on.
pub fn mappedSurfaceWindow() ?core.WindowId {
    if (!build_options.has_bar) return null;
    if (!claims[bar_id].active) return null;
    return surface_win;
}

/// Sets (or re-sets) surface `id`'s claim. Calling this with a changed edge
/// or pixel count replaces the previous claim; the caller is responsible for
/// triggering any reconcile that new geometry requires.
pub fn setClaim(comptime id: u8, edge: Edge, px: u16) void {
    // The bounds check is the indexing itself: `id` is comptime and `claims`
    // has a comptime length, so a bad id is a compile error, in every build
    // mode -- "cannot index into empty array" when has_bar is off, "index out
    // of bounds" past `max_claims` otherwise. It is deliberately NOT a
    // `std.debug.assert`: that is a no-op in ReleaseFast, which is the mode
    // this ships in, so it would have read as a guarantee while checking
    // nothing in every build that matters.
    claims[id] = .{ .edge = edge, .px = px, .active = px != 0 };
}

/// Releases surface `id`'s claim, returning usable area to full screen.
pub fn releaseClaim(comptime id: u8) void {
    setClaim(id, .top, 0);
}

/// The usable rectangular area: physical screen minus the pixels that active
/// claims take from their edges. With no active claims this is the full screen.
/// Sum of every ACTIVE claim per edge. Pure over the claim table, so the
/// arithmetic the usable-area depends on is testable without an X connection.
fn claimInsets() [4]u32 {
    // Index by @intFromEnum so the reading order below and the field order of
    // the Edge enum have one definition between them. Writing the four
    // cases out spelled out the mapping twice, and the two copies could
    // disagree: a case reordering the enum would still have compiled.
    var insets = [4]u32{ 0, 0, 0, 0 };
    for (claims) |c| {
        if (!c.active) continue;
        insets[@intFromEnum(c.edge)] += c.px;
    }
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
