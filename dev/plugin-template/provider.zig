//! provider.zig — drop-in template for a hana window sub-system module.
//!
//! COPY ME: the fastest way to start a new feature is
//!
//!     cp dev/plugin-template/provider.zig src/window/modules/myfeature.zig
//!
//! then edit the TODO markers. Nothing else needs to change: build.zig's
//! directory scan (`src/<owner>/modules/` -> <owner>_modules registry) picks
//! the file up automatically, wires your `pub const module` into the
//! generated `window_modules.modules` array, and every core dispatch loop
//! (sync coverage, restart persistence, unmanage teardown, cmd wrappers)
//! starts calling your hooks — or skips them while `null`.
//!
//! This file is INTENTIONALLY inert. It implements the full seam mechanics
//! around a trivial per-window "flagged" bit so every hook is real,
//! copy-pasteable code, but nothing in the WM ever sets the bit: coverageOn
//! returns null (no claim), serializeWindow returns null (no blob), and the
//! boot/tests are byte-identical with and without the file. Drop it into
//! src/window/modules/ and `zig build test` stays green — that is the
//! contract's litmus test.
//!
//! The full contract + onboarding guide lives in PLUGIN_PROVIDER.md.

const std = @import("std");
const constants = @import("constants");
const utils = @import("utils");
const model = @import("model");
const build_options = @import("build_options");

// ---------------------------------------------------------------------------
// Module-owned state. Every sub-system is allocation-free: a fixed,
// compile-time-bounded static store. There is NO per-model instance — the
// process runs exactly one WM, and the module store lives for the process
// lifetime. This is also why init()/deinit() must reset everything (test
// fixtures rely on it; see "test discipline" below).
// ---------------------------------------------------------------------------

/// Ceiling on concurrently flagged windows. Pick a constant from
/// `constants` when possible (e.g. constants.max_minimized); a local const
/// is fine when the feature defines its own budget.
const MAX_FLAGGED = constants.max_minimized;

/// One flagged window's record. `mask`/`seq` are just for illustration —
/// your feature stores whatever it must survive a restart (or nothing).
const Rec = struct {
    win: model.WindowId,
    flag: bool = true,
    seq: u32,
};

var g_recs: [MAX_FLAGGED]Rec = undefined;
var g_len: usize = 0;
var g_seq: u32 = 0;

fn findRec(win: model.WindowId) ?usize {
    for (0..g_len) |i| {
        if (g_recs[i].win == win) return i;
    }
    return null;
}

// ---------------------------------------------------------------------------
// REQUIRED hooks. A module that stores per-window state binds all five;
// bind only the ones your feature uses, the rest stay null.
//
// init/deinit ordering: the wire layer calls every module's init during
// boot (after atom cache setup, so utils.getAtomOrZero works), in registry
// order, and every deinit during shutdown/restart in the same order.
// ---------------------------------------------------------------------------

/// Lifecycle: reset ALL module state. Called once at boot and at every
/// re-init (restart). Deinit must perform the same reset so a run ends
/// state-free and tests can init/deinit per fixture.
pub fn init() anyerror!void {
    g_len = 0;
    g_seq = 0;
}

/// Lifecycle: tear down. Same reset as init(); nothing else (no global
/// allocator, no OS handles in this template — free those here if your
/// module owns any).
pub fn deinit() void {
    g_len = 0;
    g_seq = 0;
}

/// Per-window teardown, dispatched by the wire layer after model.unregister
/// (the model itself stays feature-free and never names this module). DROP
/// every record for `win` here — a dangling record is how recycled XIDs
/// inherit stale state (the T12 test class).
pub fn onWindowGone(win: u32) void {
    if (findRec(win)) |idx| {
        g_recs[idx] = g_recs[g_len - 1];
        g_len -= 1;
    }
}

/// Persistence — write side (plugin.WindowModule.serializeWindow).
///
/// Returns an opaque per-window blob for the session file, or null when this
/// module does NOT own the window's `ext` slot.
///
/// OWNERSHIP RULE — at most one module may return bytes per window:
/// restart_state saves ONE `ext` blob per window and the registry loop asks
/// modules in order, running the FIRST that returns. Ownership is derived
/// from the model's presence, which is exactly how minimize (claims parked
/// windows) and fullscreen (claims non-parked records) stay disjoint. Your
/// module must apply the same presence-driven exclusivity — e.g. "only when
/// presence == .present and I have a record" — so the sets can never
/// overlap regardless of registry order.
///
/// The model arrives as `*anyopaque` so this seam stays free of a model
/// type at the contract boundary; cast it back on this side.
pub fn serializeWindow(model_ptr: *anyopaque, win: u32, alloc: std.mem.Allocator) ?[]const u8 {
    const m: *const model.Model = @ptrCast(@alignCast(model_ptr));
    const idx = findRec(win) orelse return null;
    // Presence-driven exclusivity (see ownership rule above). TODO: pick the
    // presence values your feature owns (here: only .present windows).
    const e = m.store.get(win) orelse return null;
    if (e.presence != .present) return null;

    // SELF-IDENTIFYING BLOB: [0] is a magic byte unique to this module.
    // The adoption loop dispatches every non-null blob through every module's
    // deserializeWindow; the magic byte is what prevents mis-claims. Pick a
    // distinct tag; 0x5A ('Z') and 0x46 ('F') are taken.
    const held = alloc.alloc(u8, 6) catch return null;
    held[0] = 0x50; // 'P' — your module's magic tag
    held[1] = if (g_recs[idx].flag) 1 else 0;
    std.mem.writeInt(u32, held[2..6], g_recs[idx].seq, .little);
    return held;
}

/// Persistence — read side (plugin.WindowModule.deserializeWindow).
///
/// Called during adoption for EVERY record whose `ext` is non-null (parked,
/// covering, or anything a module wrote). Return true iff this module
/// claimed the blob — check BOTH the magic byte and the length, return false
/// for anything else so the registry loop can continue to other modules.
/// Unclaimed blobs leave the window in its default (present, tiled) state —
/// that graceful degrade is the contract when a feature is stripped between
/// two runs.
///
/// Replay your state against the LIVE model: the entry is already registered
/// (present + tiled + home_ws set); flip presence/geometry as your feature
/// requires. Idempotent: never crash on a double-claim (findRec check).
pub fn deserializeWindow(win: u32, bytes: []const u8, ptr: *anyopaque) bool {
    if (bytes.len < 1 or bytes[0] != 0x50) return false; // not ours
    if (bytes.len != 6) return false;
    if (findRec(win) != null) return true; // already adopted
    if (g_len >= MAX_FLAGGED) return false; // capacity BEFORE mutation
    const m: *model.Model = @ptrCast(@alignCast(ptr));
    const e = m.store.getPtr(win) orelse return false;
    // TODO: apply whatever this blob means to e (anchor/presence/mask...).
    // Example — a feature that hides the window tunes presence to .parked:
    //   e.presence = .parked;
    _ = e;
    g_recs[g_len] = .{ .win = win, .flag = bytes[1] != 0, .seq = std.mem.readInt(u32, bytes[2..6], .little) };
    g_len += 1;
    return true;
}

// ---------------------------------------------------------------------------
// OPTIONAL hooks — bind only what your feature owns; everything else stays
// null and every dispatch loop skips this module for that hook.
// ---------------------------------------------------------------------------

/// Coverage seam (plugin.WindowModule.coverageOn): "which window owns the
/// screen on `ws`, if any". sync calls it once per reconcile, through the
/// registry, INSTEAD of scanning the model for fullscreen state. Rules:
///   - first module in registry order that returns non-null claims the ws;
///   - a STOPPED (parked) window must never claim (returns null) — this is
///     how minimize-from-fullscreen ghosts correctly release the screen;
///   - the winning window is placed at the full screen rect, and every other
///     covering window is parked by sync (no per-module wire traffic).
///
/// A module that never claims a screen leaves this null.
pub fn coverageOn(m: *const model.Model, ws: model.WSId) ?model.WindowId {
    for (0..g_len) |i| {
        const rec = &g_recs[i];
        if (!rec.flag) continue; // TODO: your "claims the screen" predicate
        const e = m.store.get(rec.win) orelse continue;
        if (e.presence == .parked) continue; // never claim for hidden windows
        // TODO: your visibility rule, e.g. `rec.ws == ws or model.visibleOn(...)`.
        _ = ws;
        return rec.win;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Feature-to-feature interaction (when your feature must ask another one).
// Two hard rules (see PLUGIN_PROVIDER.md §5):
//   1. `@import("otherfeature")` may appear ONLY inside a function body,
//      gated by `if (build_options.has_otherfeature)`. Never in a signature,
//      a top-level declaration, or a struct type.
//   2. Shared vocabulary types (a struct two modules both need) live in
//      model.zig — never inside either module.
//
// Pattern (mirrored from workspaces/floating):
//   if (build_options.has_fullscreen) {
//       if (@import("fullscreen").isFullscreenMode(m, win)) return .ignored;
//   }

// ---------------------------------------------------------------------------
// This module's window sub-system contribution: the build-generated registry
// reads this exact export. Only the fields you set are dispatched; changing
// signatures here breaks EVERY module, so keep them verbatim.
pub const module: @import("plugin").WindowModule = .{
    .init = init,
    .deinit = deinit,
    .onWindowGone = onWindowGone,
    .serializeWindow = serializeWindow,
    .deserializeWindow = deserializeWindow,
    .coverageOn = coverageOn,

    // The following hooks exist for feature classes that need them; bind the
    // ones you implement and DELETE the ones you don't (a leaner binding is
    // clearer than ten nulls):
    //
    //   .setEwmhFullscreenState = setEwmhFullscreenState, // EWMH property write
    //   .armPendingBarHide / .armPendingBarShow           // deferred bar hide/show
    //   .notifyConfigureIfPending                         // ConfigureNotify follow-up
    //   .startDrag / .stopDrag / .updateDrag / .isDragging / .isResizingWindow
    //   .getDragLastRect / .cancelDragForWindow           // pointer drag/resize cmd set
};