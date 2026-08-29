//! core/screen.zig: the usable-screen-area fact.
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

const core = @import("core");
const utils = @import("utils");
const build_options = @import("build_options");

/// Which screen edge a claim occupies.
pub const Edge = enum { top, bottom, left, right };

const Claim = struct {
    edge: Edge = .top,
    px: u16 = 0,
    active: bool = false,
};

// Compile-time number of claim slots. Each surface that exists in a given
// build owns one slot, addressed by a comptime id. Today only the bar claims
// screen space; a future surface adds its own slot here (and its own id
// constant), keeping the ledger fully comptime-sized (no allocation, no
// runtime registration).
pub const max_claims = if (build_options.has_bar) 1 else 0;

// The bar is surface id 0 (present only when has_bar).
pub const bar_id: ?u8 = if (build_options.has_bar) 0 else null;

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
    return surface_win != null and surface_win.? == win;
}

/// The chrome surface's window id when it currently occupies screen space
/// (has an active claim); null otherwise. Used for raise-above stacking.
pub fn mappedSurfaceWindow() ?core.WindowId {
    if (surface_win == null) return null;
    for (claims) |c| if (c.active) return surface_win;
    return null;
}

/// Sets (or re-sets) surface `id`'s claim. Calling this with a changed edge
/// or pixel count replaces the previous claim; the caller is responsible for
/// triggering any reconcile that new geometry requires.
pub fn setClaim(comptime id: u8, edge: Edge, px: u16) void {
    claims[id] = .{ .edge = edge, .px = px, .active = px != 0 };
}

/// Releases surface `id`'s claim, returning usable area to full screen.
pub fn releaseClaim(comptime id: u8) void {
    claims[id] = .{ .edge = .top, .px = 0, .active = false };
}

/// The usable rectangular area: physical screen minus the pixels that active
/// claims take from their edges. With no active claims this is the full screen.
pub fn workArea(screen: core.Screen) utils.Rect {
    var top: u32 = 0;
    var bottom: u32 = 0;
    var left: u32 = 0;
    var right: u32 = 0;
    for (claims) |c| {
        if (!c.active) continue;
        switch (c.edge) {
            .top => top += c.px,
            .bottom => bottom += c.px,
            .left => left += c.px,
            .right => right += c.px,
        }
    }
    const w = screen.width_in_pixels;
    const h = screen.height_in_pixels;
    return .{
        .x = @intCast(left),
        .y = @intCast(top),
        .width = @intCast(w -| left -| right),
        .height = @intCast(h -| top -| bottom),
    };
}
