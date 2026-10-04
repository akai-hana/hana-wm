//! Config reload: load, validate, and atomically swap in a new
//! config, then tear down and rebuild only the subsystems whose
//! settings changed, split out of events.zig (review 05-input
//! round 2). A transition concern -- driven by the reload flag
//! the event loop consumes -- not per-event path work.

const core = @import("core");
const log = @import("log");
const config = @import("config");
const input = @import("input");
const window = @import("window");
const admission = @import("admission");
const actions = @import("actions");
const grabs = @import("grabs");
// The bar's hook set lives in the `surfaces` composition root (comptime `null`
// when absent), so the `if (changes.bar)` call below compiles away.
const surfaces = @import("surfaces").Surfaces;

/// Loads and validates a new config, then applies it atomically via pointer
/// swap. On failure the old config remains active.
///
/// Ordering is load-bearing:
///   1. Keybind resolution runs pre-swap on the new config.
///   2. The swap precedes subsystem reloads (reloadBorders / reloadConfig /
///      surfaces.onReload) so they rebuild from the NEW config. (The old ordering kept
///      stale settings, then freed string slices the new bar had shallow-copied;
///      a use-after-free on the next draw.)
///   3. grabKeybindings() runs post-swap because fillGrabCookies() reads the
///      live config.
///   4. errdefer frees the heap-allocated new config if anything fails pre-swap.
///      Post-swap all calls are infallible, so no errdefer is needed.
pub fn handleConfigReload() !void {
    log.info("Reload requested", .{});
    const cs = core.getState();

    var source: config.DefaultSource = .fallback;
    // Load the LIVE config tree, never the re-exec snapshot restart.config_dir_env
    // points at: the pin stays set for the whole process lifetime after the
    // first reload_hana, and honoring it here would re-read the frozen last-
    // good snapshot instead of the user's freshly edited files, so bind/theme
    // changes would never hot-reload. refreshSnapshot below then re-freezes
    // the now-live config as the re-exec source.
    const new_config = config.loadConfigDefault(cs.alloc, &source, false) catch |err| {
        // A TOML parse error already reported per-line warnings; treat it as
        // a hard failure and keep the live config rather than swapping in a
        // partially-merged one. Nothing to deinit here: the load failed before
        // new_ptr existed, and the load path's own errdefers released its
        // internals. The early return also skips keybind regrabbing. The
        // failure is reported once, at the caller (the sole reload reporter).
        return err;
    };
    // Heap-allocate so the swap is a pointer exchange, not a by-value copy.
    // The defer below frees the allocation unless the swap commits.
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
    if (source != .user) {
        log.err(
            "Config reload rejected: no user config file found. " ++
                "Keeping current config (the embedded fallback is boot-only)",
            .{},
        );
        return;
    }

    try config.validate(new_ptr);
    // XKB exists for the whole process lifetime (init at boot, deinit only at
    // shutdown), so this reload never sees a null state.
    input.buildKeybinds(new_ptr.keybindings.items);

    // Per-subsystem change detection, BEFORE the swap: it reads both boxes, and
    // the swap below releases the old one. Detecting first is what lets the
    // hand-off be a single core call instead of a pointer swap that leaves two
    // sites reasoning about who frees what. Only tear down and rebuild the
    // subsystems whose config actually changed -- e.g. a bar color tweak should
    // not regrab keybindings, and a keybinding change should not rebuild the
    // bar.
    const changes = config.detectChanges(cs.config, new_ptr);

    // Ownership moves to the new box and the displaced one is released in the
    // same call, so shutdown's `core.deinitOwnedConfig()` and this reload can
    // never both free the same box.
    core.replaceOwnedConfig(new_ptr);
    committed = true;

    // Freeze the now-live config as the re-exec source: a later reload_hana
    // (binary-only reload) boots from this snapshot rather than from the
    // (possibly mid-edit or broken) config files.
    config.refreshSnapshot(cs.alloc);

    // The bar survives a reload that does not touch it: it reads the live
    // config at draw time, so nothing has to be re-pointed and no copy can
    // be left borrowing the config the caller is about to free.
    //
    // No `has_bar` guard: `surfaces.onReload` is the no-op hook when no
    // surface module is compiled in, so the gate is already inside the type.
    if (changes.bar) surfaces.onReload();
    if (changes.tiling) {
        actions.applyConfigReload();
        // Borders sweep AFTER applyConfigReload: its reconcile rebuilds geometry,
        // and sweeping first would send every border twice -- once here, once
        // again deduped against fresh state. Sweeping last lets borders.apply
        // dedup against entries the reconcile just wrote.
        window.reloadBorders();
        // Rebuild after the swap so borrowed key slices point into the new config's memory.
        admission.buildRulesMap();
    }

    if (changes.keys) grabs.grabKeybindings();

    log.info("Reload complete (bar={} tiling={} keys={})", .{ changes.bar, changes.tiling, changes.keys });
}
