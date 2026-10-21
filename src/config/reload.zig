//! Config reload: load, validate, and atomically swap in a new config, then
//! rebuild the subsystems that read it. Keybindings regrab only when the key
//! PAIR layout changed; bar and tiling rebuild unconditionally.
//!
//! Boundary: this file is config loading + subsystem rebuild ORCHESTRATION.
//! After the pointer swap it hands param stamping to
//! `seed.reloadAndReconcile()` (pure config→model) and never models state
//! itself. Session continuity across re-exec is a separate concern owned by
//! process/session.zig + process/process.zig; neither reaches through here.

const std = @import("std");
const core = @import("core");
const log = std.log.scoped(.reload);
const config = @import("config");
const keybinds = @import("keybinds");
const window = @import("window");
const admission = @import("admission");
const seed = @import("model_config");
// The bar's hook set lives in the `surfaces` composition root (comptime `null`
// when absent), so the `surfaces.onReload()` call below compiles away.
const surfaces = @import("surfaces").Surfaces;

/// The reload decision table, pure. Extracts the decision from the
/// side-effecting orchestration so it is testable without `core.getState()`
/// or an X connection. `handleConfigReload` is the only caller and keeps
/// every side effect (reporting, freeing, swapping, rebuilding) to itself.
///
/// detectChanges runs PRE-swap (it reads both boxes); every rebuild below the
/// swap runs POST-swap so it stamps the config_rev the swap just bumped.
pub const Decision = enum {
    /// Load failed: the live config stays put, the keybind regrab is skipped,
    /// and the caller reports the error once (the sole reload reporter).
    fail_keep_old,
    /// Load succeeded but not from a user file (the embedded fallback, which
    /// is boot-only): soft-reject, keep the live config, and free the
    /// short-lived load. Not an error, but nothing is rebuilt.
    reject_keep_old,
    /// Load succeeded from the user's files: detectChanges pre-swap, then the
    /// atomic swap, then the rebuild chain post-swap.
    apply_new,
};

/// Pure decision: `loaded` is whether `loadConfigDefault` returned a config;
/// `source` is the out-param it filled (meaningful only when it did).
pub fn decide(loaded: bool, source: config.DefaultSource) Decision {
    if (!loaded) return .fail_keep_old;
    return if (source == .user) .apply_new else .reject_keep_old;
}

/// Loads and validates a new config, then applies it atomically via pointer
/// swap. On failure the old config remains active.
///
/// Ordering is load-bearing:
///   1. detectChanges runs pre-swap on (old, new) so the swap below can
///      release the old box while both are still borrowed here.
///   2. The swap precedes subsystem reloads (reloadBorders / reloadConfig /
///      surfaces.onReload) so they rebuild from the NEW config, and precedes
///      buildKeybinds so the resolver stamps the post-swap config_rev.
///   3. buildKeybinds runs POST-swap: its KeybindResolver stamps
///      core.config_rev() as the rev the dispatch map matches, and that rev is
///      only bumped BY the swap; stamping before the swap would leave the
///      resolver a rev behind, so lookup fails closed (no keybind dispatch).
///   4. grabKeybindings() runs post-swap because the caller hands it
///      keybinds.resolvedKeybinds(), which the buildKeybinds step above just
///      rebuilt from the new config's bindings.
///   5. errdefer frees the heap-allocated new config if anything fails pre-swap.
///      Post-swap all calls are infallible, so no errdefer is needed.
pub fn handleConfigReload() !void {
    log.info("Reload requested", .{});
    const cs = core.getState();

    var source: config.DefaultSource = .fallback;
    // Load the LIVE config tree, never the re-exec snapshot restart.config_dir_env
    // points at: the pin stays set for the whole process lifetime after the
    // first reload_hana, and honoring it here would re-read the frozen
    // last-good snapshot instead of the user's freshly edited files.
    const new_config = config.loadConfigDefault(cs.alloc, &source, false) catch |err| {
        // A TOML parse error already reported per-line warnings; treat it as
        // a hard failure and keep the live config rather than swapping in a
        // partially-merged one. Nothing to deinit here: the load failed before
        // new_ptr existed, and the load path's own errdefers released its
        // internals. The early return also skips keybind regrabbing. The
        // failure is reported once, at the caller (the sole reload reporter).
        // The decision is `fail_keep_old` regardless of whatever the failed
        // load left in `source`: load-ok-ness dominates the table.
        std.debug.assert(decide(false, source) == .fail_keep_old);
        return err;
    };
    // Heap-allocate so the swap is a pointer exchange, not a by-value copy.
    const new_ptr = try cs.alloc.create(@TypeOf(new_config));
    new_ptr.* = new_config;
    // The defer owns BOTH the Config internals and the box itself, so any
    // pre-swap failure or early return frees the whole allocation. `committed`
    // flips once the swap makes the live state own it; post-swap all calls are
    // infallible, so the defer stays dormant.
    var committed = false;
    defer if (!committed) {
        new_ptr.deinit(cs.alloc);
        cs.alloc.destroy(new_ptr);
    };

    // A load with no user config comes back as a successful embedded
    // fallback load. Boot keeps that fallback; on RELOAD a missing user config
    // must NOT silently swap in the fallback. loadConfigDefault reports the
    // source (user vs fallback) directly, so no second existence probe is
    // needed. This plain return is NOT an error, but the defer still fires
    // (not committed) and frees the short-lived fallback allocation.
    switch (decide(true, source)) {
        // Only reachable with a FAILED load; that path returns from the catch
        // above and never gets here.
        .fail_keep_old => unreachable,
        .reject_keep_old => {
            log.err(
                "Config reload rejected: no user config file found. " ++
                    "Keeping current config (the embedded fallback is boot-only)",
                .{},
            );
            return;
        },
        .apply_new => {},
    }

    // Domain invariants and the warn-only checks run INSIDE composed.parse
    // (each fragment's validate follows its parse), so a config that loaded
    // here is already validated -- there is no separate validate step.
    // Keys change detection, BEFORE the swap: it reads both boxes, and the
    // swap below releases the old one. Detecting first is what lets the
    // hand-off be a single core call instead of a pointer swap that leaves two
    // sites reasoning about who frees what. Only the regrab is skipped for an
    // unchanged pair layout; bar and tiling rebuild unconditionally so no
    // borrowed state outlives the box the swap releases.
    const changes = config.detectChanges(cs.config, new_ptr);

    // Ownership moves to the new box and the displaced one is released in the
    // same call, so shutdown's `core.deinitOwnedConfig()` and this reload can
    // never both free the same box.
    core.replaceOwnedConfig(new_ptr);
    committed = true;

    // Keybind resolution runs POST-swap so the resolver's stamped config_rev
    // matches the rev the swap just bumped (see the ordering doc). XKB exists
    // for the whole process lifetime (init at boot, deinit only at shutdown),
    // so this reload never sees a null state.
    keybinds.buildKeybinds(new_ptr.core.keybindings.items);
    // Freeze the now-live config as the re-exec source: a later reload_hana
    // (binary-only reload) boots from this snapshot rather than from the
    // (possibly mid-edit or broken) config files.
    config.refreshSnapshot(cs.alloc);

    // The bar survives a reload that does not touch it: it reads the live
    // config at draw time. No `has_bar` guard: `surfaces.onReload` is the
    // no-op hook when no surface module is compiled in.
    surfaces.onReload();
    seed.reloadAndReconcile();
    // Borders sweep AFTER the seed+reconcile: its reconcile rebuilds geometry,
    // and sweeping first would send every border twice -- once here, once
    // again deduped against fresh state. Sweeping last lets the sweep
    // dedup against entries the reconcile just wrote.
    window.reloadBorders();
    // Rebuild after the swap so borrowed key slices point into the new config's memory.
    admission.buildRulesMap();

    if (changes.keys) keybinds.grabKeybindings(keybinds.resolvedKeybinds());

    log.info("Reload complete (keys={})", .{changes.keys});
}
