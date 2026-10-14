//! Grab-wrapped focus operations: the atomic commit API for the two-phase
//! protocol, plus the focus cycle.
//!
//! These wrap prepare/apply (focus.zig) in a server grab with a reconcile,
//! ensuring focus, borders, and geometry all land atomically under one
//! server grab. The protocol itself -- module state, the etiquette table,
//! the prepare/apply split, button grabs -- stays in focus.zig, which
//! re-exports everything here so `focus.*` remains the single import
//! surface for callers.

const std = @import("std");

const types = @import("types");
const focus = @import("focus");
const pipeline = @import("pipeline");
const model_mod = @import("model");

// Grab-wrapped focus operations (full atomicity)
//
// These wrap the two-phase protocol (prepare + apply) in a server grab
// with a reconcile, ensuring focus, borders, and geometry all land
// atomically under one server grab.

/// Atomically focus `win` with `reason`. Focus protocol, borders, and geometry
/// land inside one server grab. Drop-in for the old setFocus path.
pub fn grabFocus(win: u32, reason: focus.Reason) void {
    grabFocusWithDuty(win, reason, null);
}

/// Focus `win` with an optional `duty` that runs inside the SAME grab, after
/// the focus protocol but before the reconcile. Used by the focus-cycle path
/// to apply the viewport snap to the freshly focused window, so a Mod+k/Mod+j
/// that scrolls the viewport lands focus + geometry in one grab+reconcile
/// instead of focus-then-snap's two. The duty is skipped whenever the
/// transition resolves to `.none`, so a rejected target (no_input) never
/// leaves a stray viewport move.
///
/// Hover focus (`.mouse_enter`) is a focus-only commit: nothing geometric
/// changes, so it skips the reconcile (dwm's enternotify -> focus()). Borders
/// repaint via the per-batch sweep on the commit's focus bump.
pub fn grabFocusWithDuty(win: u32, reason: focus.Reason, duty: ?*const fn () void) void {
    const ft = focus.prepareFocus(win, reason);
    if (!focus.yieldsModelFocus(ft)) return;
    model_mod.setFocus(pipeline.mut(), win);
    if (reason == .mouse_enter) {
        // Focus-only commit: nothing geometric changes, so skip the
        // reconcile (dwm's enternotify -> focus()). Borders repaint via the
        // per-batch sweep on the commit's focus bump.
        //
        // grabOnly, not grabScoped: this path never reconciles, so building
        // a ctx (and running the model-mutating preReconcileDuties) would
        // leave the model and the server disagreeing -- the exact hazard
        // ScopedGrab.reconcileNow exists to prevent.
        const g = pipeline.grabOnly();
        defer g.deinit();
        focus.applyPendingFocus(ft);
        return;
    }
    // A null duty is a first-class case, not a contract violation: `grabFocus`
    // passes one, and `reconcileGrabFocus` guards the call
    // (`if (self.duty) |d| d();`).
    pipeline.reconcileGrabFocus(.{}, ft, .before, duty);
}

// Window focus cycling
//
// `cycleTarget` fills its OWN stack scratch (see below); there is deliberately
// no module-level buffer here. The cycle pool is not restricted to tiled slots
// (floating windows are admitted too), so the buffer is sized by the model
// store capacity rather than max_tiled_windows.

/// Cycle focus one step, committing the viewport-snap duty in the SAME grab.
///
/// This is the coupled form. The two calls the input path used to make --
/// `if (focus.cycleTarget(dir)) |t| focus.grabFocusWithDuty(t, .user_command,
/// &actions.snapViewportFocusedDuty)` -- put the pool resolution and the
/// commit in the CALLER's hands, and nothing tied the duty to the transition
/// it belongs to: resolve a target, then commit it with a different duty or
/// none, and the snap the cycle exists to fold in silently does not happen
/// (one extra grab-and-reconcile later, or not at all). The "the snap rides
/// along in the cycle's grab" rule lived only in a comment at the call site.
///
/// Deliberately NOT the whole refactor: `cycleTarget` is still `pub` for the
/// pure read. Privatizing it is the right end state, but its only other
/// consumers are assertions in the X-gated focus_test that this environment
/// cannot execute, and the mechanical conversion (cycleTarget reads -> cycleFocus
/// commits, which mutates the very order/focus state the following assertions
/// read) is not a rewrite I can verify here. Left public, with the coupling
/// now enforced on the path that matters.
pub fn cycleFocus(dir: types.Dir, duty: *const fn () void) void {
    const target = cycleTarget(dir) orelse return;
    grabFocusWithDuty(target, .user_command, duty);
}

/// Resolve the visible window a focus-cycle step would land on, or null when
/// the step is a no-op (no visible windows, or the only visible window is
/// already focused). Pure read: no focus change, no grab -- the reason
/// `cycleFocus` exists is to stop the caller from having to pair this with a
/// commit itself. The Mod+k/Mod+j input path folds the target's viewport snap
/// into the SAME grab as the focus transition (one grab+reconcile instead of
/// focus-then-snap).
pub fn cycleTarget(dir: types.Dir) ?u32 {
    const forward = dir == .forward;
    // Caller-owned scratch, like every other snapshot buffer in this layer
    // (query.zig): the ordering itself comes from model.collectCyclePool,
    // which anchors the cycle on the workspace's tiled_order -- so Mod+j/k
    // follows the arrangement and a move/swap reorders the cycle with it.
    var buf: [model_mod.store_capacity]u32 = undefined;
    const m = pipeline.model();
    const len = model_mod.collectCyclePool(m, m.current, &buf);
    if (len == 0) return null;
    const wins = buf[0..len];
    // Single visible window: the only sensible cycle step is to focus it
    // when it isn't focused already; the modulo wrap below would otherwise
    // spin a redundant grabFocus against the same id.
    if (len == 1) {
        const only = wins[0];
        return if (focus.getFocused() == only) null else only;
    }
    // When the focused window isn't in the visible list, wrap so the very next
    // step lands on wins[0] (forward) or wins[len-1] (backward).
    const sentinel: usize = if (forward) len - 1 else 0;
    const idx = if (focus.getFocused()) |w|
        std.mem.indexOfScalar(u32, wins, w) orelse sentinel
    else
        sentinel;
    return wins[model_mod.wrapIndex(idx, if (forward) 1 else -1, len)];
}
