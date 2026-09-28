//! X event dispatch and main event loop.
//! Handles X events, OS signals, and config reload, driving the WM's main loop.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const masks = @import("masks");

const log = @import("log");
const config = @import("config");
const input = @import("input");
const window = @import("window");
const ledger = @import("ledger");
const focus = @import("focus");

const signals = @import("signals");
const pipeline = @import("pipeline");
const actions = @import("actions");
const restart = @import("restart");
const persist = @import("persist");
const spawn = @import("spawn");
const timers = @import("timers");
const build_options = @import("build_options");
// The bar's hook set lives in the `surfaces` composition root (comptime `null`
const lifecycle = @import("lifecycle");
// when absent), so every `if (build_options.has_bar)` call below compiles away.
const surfaces = @import("surfaces").Surfaces;

const fd_xcb = 0;
const fd_signal = 1;

// Maximum events dispatched per XCB batch before returning to poll, so the
// signal pipe and timer paths get fair scheduling against a chatty client.
const max_events_per_batch: usize = 128;

// Cap for the post-batch drain of XCB's internal event queue (see the drain
// loop in handleXcbEvents); a chatty client cannot fill it beyond this.
const max_queued_drain: usize = 256;

/// Dispatch table size. Must index every XCB core event code hana dispatches;
/// the highest is MappingNotify (34), so 36 leaves headroom. The table lookup
/// is guarded by this bound (dispatch()).
const event_dispatch_table = 36;

/// Upper bound for the XCB cookie scratch buffer in grabKeybindings
/// (max distinct keybindings x lock_modifiers.len combinations).
/// Raise if you ever exceed 128 keybindings.
const max_keybind_cookies = 1024;

const EventHandler = *const fn (event: *anyopaque) void;

// Casts a `fn(*T) void` event handler to the generic `EventHandler` pointer
// type via @ptrCast. Safe only because every registered handler takes a
// single pointer argument and returns void, matching EventHandler's shape
// exactly; the check below enforces that at comptime so a handler with the
// wrong signature fails to build instead of miscompiling through the cast.
inline fn asHandler(comptime f: anytype) EventHandler {
    const info = @typeInfo(@TypeOf(f)).@"fn";
    if (info.params.len != 1)
        @compileError(
            "event handler must take exactly one parameter, got " ++
                @typeName(@TypeOf(f)),
        );
    if (info.params[0].type == null or @typeInfo(info.params[0].type.?) != .pointer)
        @compileError(
            "event handler's parameter must be a single-item pointer, got " ++
                @typeName(@TypeOf(f)),
        );
    if (info.return_type != void)
        @compileError("event handler must return void, got " ++ @typeName(@TypeOf(f)));
    return @ptrCast(&f);
}

fn handleExpose(event: *anyopaque) void {
    const e = core.eventCast(*xcb.xcb_expose_event_t, event);
    surfaces.handleExpose(e);
}

fn handlePropertyNotify(event: *anyopaque) void {
    const e = core.eventCast(*xcb.xcb_property_notify_event_t, event);
    window.handlePropertyNotify(e);
}

// Routes ConfigureNotify to the fullscreen deferred-bar-hide/show logic.
fn handleConfigureNotify(event: *anyopaque) void {
    const e = core.eventCast(*xcb.xcb_configure_notify_event_t, event);
    // A client that resizes itself while we had it parked offscreen has undone
    // our park, and the off-workspace elision would not notice. Flag it so the
    // next reconcile re-parks it (ledger.markParkedDirty).
    //
    // The managed-window filter is load-bearing, not an optimization: this
    // event fires for every client on the display, including the ones we do
    // not manage, and markParkedDirty already ignores anything not currently
    // parked -- so an unfiltered call would be a wasted ledger lookup per
    // configure event on the whole session. It also means a managed window's
    // OWN configure (the echo of a park we just sent) sets a flag we then
    // clear, costing one extra park resend per workspace switch and no more.
    if (window.isValidManagedWindow(e.window)) ledger.markParkedDirty(e.window);
    window.dispatchAll(.notifyConfigureIfPending, .{ e.window, e.width, e.height });
}

// Notifies fullscreen of the destroyed window before delegating to window.zig.
// This clears any pending deferred bar-show for a window that exits fullscreen
// and is then destroyed before it can send a ConfigureNotify.
fn handleDestroyNotify(event: *anyopaque) void {
    const e = core.eventCast(*xcb.xcb_destroy_notify_event_t, event);
    window.dispatchAll(.onWindowGone, .{e.window});
    window.handleDestroyNotify(e);
}

// Adapts input.handleMappingNotify to the EventHandler shape. The keymap
// rebuild it triggers doesn't consult any MappingNotify fields, so the
// event pointer is discarded.
fn handleMappingNotify(event: *anyopaque) void {
    _ = event;
    input.handleMappingNotify();
}

// O(1) dispatch via a comptime-built table indexed by XCB event type (low 7 bits).
const dispatch_table = blk: {
    var table = [_]?EventHandler{null} ** event_dispatch_table;

    table[xcb.XCB_ENTER_NOTIFY] = asHandler(window.handleEnterNotify);
    table[xcb.XCB_LEAVE_NOTIFY] = asHandler(window.handleLeaveNotify);

    table[xcb.XCB_MAP_REQUEST] = asHandler(window.handleMapRequest);
    table[xcb.XCB_CONFIGURE_REQUEST] = asHandler(window.handleConfigureRequest);
    table[xcb.XCB_UNMAP_NOTIFY] = asHandler(window.handleUnmapNotify);
    table[xcb.XCB_DESTROY_NOTIFY] = asHandler(handleDestroyNotify);
    table[xcb.XCB_CLIENT_MESSAGE] = asHandler(window.handleClientMessage);

    table[xcb.XCB_KEY_PRESS] = asHandler(input.handleKeyPress);
    table[xcb.XCB_KEY_RELEASE] = asHandler(input.handleKeyRelease);
    table[xcb.XCB_MAPPING_NOTIFY] = asHandler(handleMappingNotify);
    table[xcb.XCB_BUTTON_PRESS] = asHandler(input.handleButtonPress);
    table[xcb.XCB_BUTTON_RELEASE] = asHandler(input.handleButtonRelease);
    table[xcb.XCB_MOTION_NOTIFY] = asHandler(input.handleMotionNotify);
    table[xcb.XCB_PROPERTY_NOTIFY] = asHandler(handlePropertyNotify);

    table[xcb.XCB_EXPOSE] = asHandler(handleExpose);

    table[xcb.XCB_CONFIGURE_NOTIFY] = asHandler(handleConfigureNotify);

    break :blk table;
};

/// True for the RandR extension-event window (base and base+1): screen/CRTC/
/// output change notifications. Bar render pacing must track monitor
/// re-configuration, so any of them triggers re-detection.
///
/// The range test uses the RAW type byte, BEFORE the 0x7F mask (both callers
/// strip send_event afterwards): the synthetic-event bit is only meaningful
/// for core events, and an extension base can legitimately be >= 0x80 (the
/// server allocates bases at/after 0x80 precisely to leave bit 7 free for
/// SendEvent on core codes). Masking first would alias such a base onto a low
/// core code (e.g. 0x85 -> 0x85 & 0x7f == 5) and break the test, silently
/// disabling refresh re-detection, misrouting the event in dispatch, and
/// reclassifying a RandR event as a coalesceable motion in isMotion.
fn isRandrEvent(t: u8) bool {
    // RandR is a bar feature (render pacing). With no bar compiled in,
    // `randrFirstEvent` is the no-op, which reports 0, and the `r != 0` test
    // below is what makes this false -- so there is no build flag to consult
    // here, and adding a hook to the contract cannot leave this unguarded.
    const r = surfaces.randrFirstEvent();
    return (r != 0 and t >= r and t <= r + 1);
}

fn dispatch(event_type: u8, event: *anyopaque) void {
    // Type 0 is an X error pseudo-event produced for a failed *unchecked*
    // request. Nothing else in this codebase subscribes to type-0, so without
    // this branch such errors would be silently dropped, making real-world
    // X11 failures (bad grabs, stale window ids, wrong atoms) undiagnosable.
    if (event_type == 0) {
        const e = core.eventCast(*xcb.xcb_generic_error_t, event);
        log.warn("Unchecked XCB request failed: code={} major={} minor={} resource={x}", .{ e.error_code, e.major_code, e.minor_code, e.resource_id });
        return;
    }

    // RandR extension events (base and base+1) trigger refresh re-detection
    // here; they sit above the fixed dispatch table and would otherwise be
    // dropped by the bounds guard below. isRandrEvent already returns false
    // when the bar is absent, pruning the branch (and the `surfaces` calls).
    if (isRandrEvent(event_type)) {
        // Pass the raw event: a CRTC-change payload carries the active mode id,
        // letting the bar resolve the rate from its cached mode table with zero
        // XCB round-trips (see hz.handleRandrNotifyEvent).
        surfaces.handleRandrEvent(event);
        return;
    }

    // `event_type` is the RAW byte. Bit 7 is XCB's SendEvent flag, so masking
    // it off is how a synthetic event recovers its real core code -- but the
    // same mask turns an EXTENSION event (bases at/above 0x80) into its low
    // seven bits, aliasing it onto some unrelated core event. RandR is handled
    // above; anything else in the extension range must be dropped here rather
    // than aliased, which is why this test precedes the mask instead of relying
    // on the bounds check after it.
    if (event_type >= 0x80) return;

    const idx = event_type & masks.core_event_code_mask; // strip XCB synthetic-event bit

    // Bounds guard, belt to the 0x80 suspenders: hana only selects core events
    // today, so nothing valid can reach here out of range.
    if (idx >= dispatch_table.len) return;
    if (dispatch_table[idx]) |handler| handler(event);
}

/// Dispatches an owned event: frees the heap-allocated XCB event after the
/// handler runs. Every dispatch site in handleXcbEvents owns its event
/// (stack- or heap-allocated by XCB), so they all funnel through here.
fn dispatchOwned(event: *anyopaque) void {
    defer std.c.free(event);
    dispatch(eventType(event), event);
}

/// The X11 event type byte (response_type) read off a generic event: the
/// first byte of every XCB event. Shared by the dispatcher (dispatchOwned) and
/// isMotion instead of re-spelling the raw `@as(*u8, @ptrCast(e)).*` read.
inline fn eventType(e: anytype) u8 {
    return @as(*u8, @ptrCast(e)).*;
}

const CookieEntry = struct { cookie: xcb.xcb_void_cookie_t, keycode: u8 };

fn fillGrabCookies(cookies: []CookieEntry) usize {
    var n: usize = 0;
    const cs = core.getState();
    // The compiled list, not cs.config.keybindings: keycodes are derived from
    // the live keyboard and deliberately not stored in config.
    for (input.resolvedKeybinds()) |kb| {
        const keycode = kb.keycode orelse continue;

        // Check once per keybinding that the full lock-modifier set fits.
        // Avoids a per-lock branch and prevents partial grabs if the buffer is nearly full.
        if (n + masks.lock_modifiers.len > cookies.len) {
            log.warn(
                "Too many keybindings. Increase max_keybind_cookies (currently {})",
                .{max_keybind_cookies},
            );
            break;
        }

        for (masks.lock_modifiers) |lock| {
            cookies[n] = .{
                .cookie = xcb.xcb_grab_key_checked(
                    cs.conn,
                    0,
                    cs.root,
                    @intCast(kb.modifiers | lock),
                    keycode,
                    xcb.XCB_GRAB_MODE_ASYNC,
                    xcb.XCB_GRAB_MODE_ASYNC,
                ),
                .keycode = keycode,
            };
            n += 1;
        }
    }
    return n;
}

fn checkGrabCookies(cookies: []const CookieEntry) usize {
    var failed: usize = 0;
    const conn = core.getState().conn;
    for (cookies) |entry| {
        if (xcb.xcb_request_check(conn, entry.cookie)) |err| {
            std.c.free(err);
            log.warn("Failed to grab keycode: {}", .{entry.keycode});
            failed += 1;
        }
    }
    return failed;
}

/// Ungrabs all keys, then re-grabs every configured keybinding across all
/// lock modifier combinations. Fires all grab cookies before reading any
/// reply to reduce round-trips.
pub fn grabKeybindings() void {
    const cs = core.getState();
    _ = xcb.xcb_ungrab_key(cs.conn, xcb.XCB_GRAB_ANY, cs.root, xcb.XCB_MOD_MASK_ANY);

    var cookies: [max_keybind_cookies]CookieEntry = undefined;
    const n = fillGrabCookies(&cookies);

    const failed = checkGrabCookies(cookies[0..n]);
    if (failed > 0) log.warn("{} keybinding(s) failed to grab", .{failed});

    _ = xcb.xcb_flush(cs.conn);
}

// Loads and validates a new config, then applies it atomically via pointer
// swap. On failure the old config remains active.
//
// Ordering is load-bearing:
//   1. Keybind resolution runs pre-swap on the new config.
//   2. The swap precedes subsystem reloads (reloadBorders / reloadConfig /
//      surfaces.onReload) so they rebuild from the NEW config. (The old ordering kept
//      stale settings, then freed string slices the new bar had shallow-copied;
//      a use-after-free on the next draw.)
//   3. grabKeybindings() runs post-swap because fillGrabCookies() reads the
//      live config.
//   4. errdefer frees the heap-allocated new config if anything fails pre-swap.
//      Post-swap all calls are infallible, so no errdefer is needed.
fn handleConfigReload() !void {
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

    if (build_options.has_bar) {
        // The bar survives a reload that does not touch it: it reads the live
        // config at draw time, so nothing has to be re-pointed and no copy can
        // be left borrowing the config the caller is about to free.
        if (changes.bar) surfaces.onReload();
    }
    if (changes.tiling) {
        actions.applyConfigReload();
        // Borders sweep AFTER applyConfigReload: its reconcile rebuilds geometry,
        // and sweeping first would send every border twice -- once here, once
        // again deduped against fresh state. Sweeping last lets borders.apply
        // dedup against entries the reconcile just wrote.
        window.reloadBorders();
        // Rebuild after the swap so borrowed key slices point into the new config's memory.
        window.buildRulesMap();
    }

    if (changes.keys) grabKeybindings();

    log.info("Reload complete (bar={} tiling={} keys={})", .{ changes.bar, changes.tiling, changes.keys });
}

// Re-exec hand-off, driven by restart.consumeReexec() in run(). The sequence
// is fixed: pin the config snapshot, persist the live session FIRST (a failed
// save aborts the hand-off and the WM keeps running on its live connection),
// then drop the X connection so the successor cannot inherit a live
// connection holding the root SubstructureRedirect grab, then execNext
// (which never returns: parent exits immediately, child execs).
fn handleReexec() !void {
    const cs = core.getState();
    log.info("Re-executing new binary", .{});

    const path = try persist.defaultStatePath(cs.alloc);
    // The path is allocator-owned; execNext never returns so this only
    // ever runs on the error/abort exits below, where the leak would else
    // live for the rest of the process lifetime.
    defer cs.alloc.free(path);
    try persist.save(cs.alloc, pipeline.model(), path);

    // One record for the whole hand-off. The snapshot is the frozen last-good
    // config, so this re-exec swaps ONLY the binary; a re-exec boot that finds
    // no snapshot (no user config was ever loaded) falls back to the normal
    // search, which reproduces today's fallback-only behavior.
    const handoff = restart.currentHandoff(path, config.reexecSnapshotPathZ()) orelse {
        log.err("Re-exec aborted: executable path unknown", .{});
        return error.ExecutablePathUnknown;
    };

    xcb.xcb_disconnect(cs.conn);
    restart.execNext(handoff);
}

/// One comptime-parameterized drain shared by the batch poll loop and the
/// post-batch queued drain (they differ only in pull function, cap, and
/// with_tail policy). Each iteration pulls from the caller's `pending`
/// slot first when `with_tail` is false, so a coalesced non-motion stashed
/// there is re-pulled (and charged) on the following iteration, preserving
/// order across batches. With `with_tail` true the terminating non-motion
/// is already charged by the collapse and is dispatched in place.
fn drainEvents(
    pending: *?*xcb.xcb_generic_event_t,
    conn: core.Connection,
    budget: *usize,
    comptime cap: usize,
    comptime pull: anytype,
    comptime with_tail: bool,
) void {
    while (budget.* < cap) {
        const event = blk: {
            if (pending.*) |p| {
                pending.* = null;
                break :blk p;
            }
            break :blk pull(conn) orelse break;
        };
        budget.* += 1;
        if (!isMotion(event)) {
            dispatchOwned(event);
            continue;
        }
        var newest = event;
        var pause: ?*xcb.xcb_generic_event_t = null;
        collapseMotionRun(&newest, &pause, conn, budget, cap, pull, with_tail);
        dispatchOwned(newest);
        if (pause) |p| {
            if (with_tail) {
                dispatchOwned(p);
            } else {
                pending.* = p;
            }
        }
    }
}

fn isMotion(e: *xcb.xcb_generic_event_t) bool {
    const t = eventType(e);
    // Exclude the RandR window before stripping the send_event bit; see
    // isRandrEvent for the raw-compare-before-mask rationale.
    if (isRandrEvent(t)) return false;
    return (t & masks.core_event_code_mask) == xcb.XCB_MOTION_NOTIFY;
}

/// Shared motion-run collapse used by both the batch loop and the queued
/// drain. `newest` is the run's newest motion so far (caller-owned; a
/// superseding motion frees it). Reads ahead with `pull` while `budget.*`
/// stays below `cap`, charging each drained motion into `budget` the same way
/// the caller's outer loop charges. The first non-motion ends the run and is
/// stashed to `pause` UNDELIVERED, so the caller emits `newest` before
/// `pause`, preserving order. `with_tail` mirrors the two budget
/// policies: the drain loop charges every pull (its terminating non-motion
/// counts against the per-iteration budget), while the batch loop charges
/// only drained motions -- its terminating non-motion is re-pulled and
/// charged by the outer loop later.
fn collapseMotionRun(
    newest: anytype,
    pause: *?*xcb.xcb_generic_event_t,
    conn: core.Connection,
    budget: *usize,
    comptime cap: usize,
    comptime pull: anytype,
    comptime with_tail: bool,
) void {
    while (budget.* < cap) {
        const next = pull(conn) orelse break;
        if (!isMotion(next)) {
            if (with_tail) budget.* += 1;
            pause.* = next;
            break;
        }
        std.c.free(newest.*);
        newest.* = next;
        budget.* += 1;
    }
}

// Drains pending XCB events for this batch, then runs post-batch housekeeping.
fn handleXcbEvents() void {
    const conn = core.getState().conn;

    // Snapshot the border-relevant fact revisions so the batch-end border
    // sweep can be skipped when nothing that affects borders changed this
    // batch (focus/workspace/tiling/fullscreen). Any bump during dispatch OR
    // the post-batch drains below (pending focus confirm, tiling settle)
    // counts, so the comparison runs after the drains.
    const facts_before = core.getState().facts;

    // Cap the number of events dispatched per batch so a chatty client
    // flooding PropertyNotify/ConfigureNotify can't starve the signal pipe and
    // timer paths (clock, cursor blink). Unread events stay in the
    // socket buffer and the fd stays readable, so they're handled on the next
    // poll round.
    //
    // Motion coalescing: a run of MotionNotify events collapses to its LAST
    // member before dispatch (drag paths only need the freshest pointer
    // position, and every extra dispatched motion costs a reconcile). The
    // first non-motion event is held in `pending` (it counts against the
    // batch cap via the drain's pull-from-pending) so ordering is preserved.
    var pending: ?*xcb.xcb_generic_event_t = null;
    var dispatched: usize = 0;
    // Charge each pulled event exactly when it is pulled. A motion run lets
    // the counter reach cap precisely (motions are charged during the
    // collapse); a trailing non-motion stashed against a full cap is
    // dispatched uncharged by the tail below -- never cap+1.
    drainEvents(
        &pending,
        conn,
        &dispatched,
        max_events_per_batch,
        xcb.xcb_poll_for_event,
        false,
    );

    // A cap exit can leave a non-motion event held in `pending` (stashed
    // during motion coalescing). It was pulled BEFORE anything the queued
    // drain below will read, so dispatch it now to preserve order: carrying it
    // to the next batch dispatched it after the (hundreds of) later events the
    // drain surfaces. On the normal (socket-empty) exit path `pending` is null.
    if (pending) |p| dispatchOwned(p);

    // Drain remaining events from XCB's internal event queue. When the
    // batch cap is hit above, events already buffered inside XCB (but not
    // in the kernel socket buffer) would otherwise wait for the next
    // poll() cycle — potentially up to the timer deadline — before being
    // dispatched. xcb_poll_for_queued_event reads only from the internal
    // queue without touching the socket, so it surfaces these stranded
    // events immediately. Motion runs collapse here too (a motion-heavy
    // read-ahead buffer — the very stream that cap-exited the batch above —
    // collapses to its newest member instead of dispatching up to 256
    // individual reconciles); with_tail=true charges the terminating
    // non-motion and delivers it in place.
    var queued_pending: ?*xcb.xcb_generic_event_t = null;
    var extra: usize = 0;
    drainEvents(
        &queued_pending,
        conn,
        &extra,
        max_queued_drain,
        xcb.xcb_poll_for_queued_event,
        true,
    );

    // Drain any spawn pipes that became readable during this event batch.
    // This catches the common case where SIGCHLD and the MapRequest arrive in
    // the same poll wakeup: the spawn pipe's EOF will be readable before
    // SIGCHLD fires, so registerSpawn runs before handleMapRequest needs the
    // spawn queue entry.
    spawn.drainPendingSpawns();

    // The post-batch stages are ORDER-SENSITIVE, and the order used to be
    // expressed only by the order these statements happened to be written in.
    // As a table the sequence is one list: inserting a stage means inserting a
    // line, and the reason each one sits where it does stays attached to it.
    const post_batch_stages = .{
        // Repaint the bar. Before the focus settle below, because that lift can
        // generate the EnterNotify this repaint needs to reflect.
        .{ .name = "bar update", .body = StageFn(postBatchBarUpdate){} },
        // Must run after the event-draining loop above: any EnterNotify a
        // tiling reflow generated has to have already been dispatched (and
        // filtered, since suppression is still active) before this lifts
        // suppression. See beginTilingOpSettle's doc comment in focus.zig.
        .{ .name = "focus settle", .body = StageFn(focus.drainTilingOpSettle){} },
        // The border sweep, only when a border-relevant fact actually changed
        // this batch; a motion/expose-only batch skips the unconditional O(N)
        // walk. Wire sends are unchanged either way (the sweep is
        // CacheMap-dedup'd), so steady-state output is identical. Last, because
        // it reads the model the two stages above may have moved.
        .{ .name = "border sweep", .body = PostBatchBorderSweep{ .facts_before = facts_before } },
    };
    // inline for: a tuple has no runtime iterator, and each element is a
    // distinct closure type, so the dispatch must be unrolled.
    inline for (post_batch_stages) |stage| stage.body.run();

    _ = xcb.xcb_flush(conn);
}

/// Post-batch stages live in named functions so the table in handleXcbEvents
/// reads as a list of stages rather than as bodies inline in a struct literal.
/// Each entry is a value-capturing struct with a `run(self)` method -- the
/// codebase's closure idiom, same shape as the reconcile bodies in
/// pipeline.zig -- so a stage can hold THIS batch's state. The table is a
/// TUPLE, not an array: the stages have different captured types, and an array
/// would have to erase them behind one uniform `body: anytype` field (which is
/// not a legal field type anyway).
///
/// This used to be a bare `*const fn () void` plus a file-scope
/// `facts_before` global, which made a batch's snapshot reachable from anywhere
/// in the file and impossible to hand to a second batch.
/// The border-sweep stage: skips the unconditional O(N) window walk unless a
/// border-relevant fact actually changed during the batch. `facts_before` is
/// the snapshot taken at the top of THIS batch, carried in the stage value
/// rather than read from a file global. Declared as a type (not a
/// `-> type` factory) because the snapshot is a runtime value: a function
/// returning a type is comptime-evaluated, so it cannot take one.
const PostBatchBorderSweep = struct {
    facts_before: core.Facts,

    fn run(self: @This()) void {
        if (std.meta.eql(self.facts_before, core.getState().facts)) return;
        window.updateWorkspaceBordersIfNeeded();
    }
};

/// Post-batch stages live in named functions so the table above reads as a
/// list of stages rather than as bodies inline in a struct literal.
fn postBatchBarUpdate() void {
    surfaces.updateIfDirty();
}

/// Wraps a stateless `fn () void` in the closure shape the stage table holds.
/// A no-op adapter rather than a second dispatch mechanism.
fn StageFn(comptime f: *const fn () void) type {
    return struct {
        fn run(_: @This()) void {
            f();
        }
    };
}

pub fn run() void {
    const cs = core.getState();
    const x_fd: std.posix.fd_t = xcb.xcb_get_file_descriptor(cs.conn);
    // A dead connection reports -1. Polling -1 sets no revents and never
    // returns POLLNVAL, and the loop's default deadline is -1 (block forever),
    // so the process would sit here with a broken X connection and no way to
    // learn it: no hang, no exit, no log line. Treat it as the end of the
    // session instead.
    if (x_fd < 0) {
        log.err("X connection is no longer usable (fd={d}); ending the event loop", .{x_fd});
        lifecycle.quit();
        return;
    }
    const signal_fd: std.posix.fd_t = signals.readFd();

    // Fixed slots first (x_fd, signal_fd) so the fd_xcb/fd_signal indices stay
    // valid, then one slot per in-flight spawn pipe. The spawn count changes as
    // commands come and go, so the set is a slice rebuilt each round rather
    // than a fixed array: this is the "dynamic fd count" the item warns about,
    // and it is bounded by spawn.max_read_fds.
    var poll_buf: [2 + spawn.max_read_fds]std.posix.pollfd = undefined;
    var spawn_fds: [spawn.max_read_fds]std.posix.fd_t = undefined;
    poll_buf[fd_xcb] = .{ .fd = x_fd, .events = std.posix.POLL.IN, .revents = 0 };
    poll_buf[fd_signal] = .{ .fd = signal_fd, .events = std.posix.POLL.IN, .revents = 0 };
    const n_spawn: usize = blk: {
        const rds = spawn.readFds(&spawn_fds);
        for (rds, 2..) |fd, i| poll_buf[i] = .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 };
        break :blk rds.len;
    };
    const fds: []std.posix.pollfd = poll_buf[0 .. 2 + n_spawn];

    // Core owns the timer list; the surfaces hook is one entry in it (see
    // timers.Timers). Built once, outside the loop, because the source set
    // cannot change while the loop runs.
    var source_buf: [1]timers.Source = undefined;
    const n_sources: usize = if (build_options.has_bar) blk: {
        source_buf[0] = surfaces.pollTimeoutMs;
        break :blk 1;
    } else 0;
    const loop_timers: timers.Timers = .{ .sources = source_buf[0..n_sources] };

    while (lifecycle.running.load(.acquire)) {
        // No built-in deadline: with no timer sources the loop blocks until
        // an X event or signal arrives. Timer sources today are exclusively a
        // bar concern (clock segment, prompt cursor blink, carousel marquee),
        // and the bar contributes exactly ONE entry -- it reduces over its own
        // modules. A second core-side timer is a new list entry here, not a
        // new branch at the call site, and a timeout wake must be handed to
        // the bar for repaint rather than worked around in core.
        const poll_timeout_ms: i32 = loop_timers.deadlineMs() orelse -1;

        const poll_rc = std.os.linux.poll(fds.ptr, fds.len, poll_timeout_ms);
        const ready: usize = switch (std.posix.errno(poll_rc)) {
            .SUCCESS => @intCast(poll_rc),
            .INTR => continue,
            else => |err| {
                log.err("poll error: {s}", .{@errorName(std.posix.unexpectedErrno(err))});
                continue;
            },
        };

        // Drain signals BEFORE the reload/reexec flags are consumed below. A
        // signal byte (SIGUSR1/SIGHUP) dispatches the matching request, which
        // sets a flag AND writes a wake byte into this same pipe; consuming
        // flags first let the byte be drained-and-discarded in the same poll
        // iteration, leaving the flag set but nothing to wake the loop again
        // (poll sleeps until unrelated X traffic or a timer). Draining first
        // makes the consumption below see the flag it just set.
        if ((fds[fd_signal].revents & std.posix.POLL.IN) != 0)
            signals.drainAndDispatch(signal_fd);

        // A spawn pipe with output ready: drain it now instead of waiting for
        // the next X event or SIGCHLD. POLL.ERR/POLL.HUP count too, because a
        // child that exits without writing still has to be read to EOF for
        // finishSpawn to classify the result. Non-blocking by construction.
        var spawn_ready = false;
        for (fds[2..]) |pf| {
            if ((pf.revents & (std.posix.POLL.IN | std.posix.POLL.ERR | std.posix.POLL.HUP)) != 0)
                spawn_ready = true;
        }
        if (spawn_ready) spawn.drainPendingSpawns();

        // The reload flag is set by SIGHUP and the reload_config keybinding
        // (proc.reload, which writes a wake byte to the pipe; the byte can be
        // dropped if the pipe is full). Consume it every iteration, BEFORE the
        // ready split: confining it to the ready>0 branch let a flag-only
        // request stall on timeout wakeups until unrelated X traffic arrived.
        //
        // Config reload is consumed BEFORE re-exec: a chained bind
        // (["reload_config", "reload_hana"]) sets both flags in one dispatch,
        // and reload_config must apply + validate (and refresh the re-exec
        // snapshot) before the successor boots from that snapshot. A reload
        // that fails keeps the last-good snapshot, so the re-exec still lands
        // on the previously live config.
        if (lifecycle.consumeReload())
            handleConfigReload() catch |err| log.err("Reload failed: {}", .{err});

        if (restart.consumeReexec())
            handleReexec() catch |err| log.err("Re-exec failed: {}", .{err});

        if (ready == 0 and poll_timeout_ms >= 0) {
            surfaces.onPollWakeup();
            _ = xcb.xcb_flush(cs.conn);
        } else if ((fds[fd_xcb].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP)) != 0) {
            log.err("X11 connection error, shutting down", .{});
            break;
        } else if ((fds[fd_xcb].revents & std.posix.POLL.IN) != 0) {
            handleXcbEvents();
        }

        // Run any refresh-rate re-detection deferred by a RandR event. It
        // performs synchronous XCB round-trips, so it must run here, outside
        // event dispatch, never mid-batch. RandR is a bar feature: without a
        // bar the extension is never queried and nothing is ever pending.
        surfaces.runPendingRedetect(cs.conn);

        if (build_options.has_bar) surfaces.updateClock();
    }
}
