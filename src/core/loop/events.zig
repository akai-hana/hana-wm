//! X event dispatch and main event loop.
//! Drives the WM: dispatches X11 events, OS signals, and config reload; runs
//! the poll/select main loop with timer sources.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const masks = @import("masks");

const log = @import("log");
const xtrace = @import("xtrace");
const config = @import("config");
const scale = @import("dpi");
const hz = @import("hz");
const input = @import("input");
const grabs = @import("grabs");
const window = @import("window");
const ledger = @import("ledger");
const focus = @import("focus");

const signals = @import("signals");
const pipeline = @import("pipeline");
const handoff = @import("handoff");
const spawn = @import("spawn");
const build_options = @import("build_options");
// The bar's hook set lives in the `surfaces` composition root (comptime `null`
// when absent), so every `if (build_options.has_bar)` call below compiles away.
const surfaces = @import("surfaces").Surfaces;
const lifecycle = @import("lifecycle");
// Config reload (the SIGHUP / reload_config transition) lives in
// reload.zig (review 05-input round 2): a lifecycle concern, not
// per-event path work.
const reload = @import("reload");

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
const dispatch_table_len = 36;

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

// Adapts input.handleMappingNotify to the EventHandler shape. Only the
// `request` field matters: it says WHICH mapping changed, and only a keyboard
// mapping change invalidates the keycode->keysym table. A keyboard
// change also makes the installed key grabs stale, and the regrab runs HERE
// rather than inside input because grabs reads input's resolved keybind list:
// calling it from there closed an import cycle (the same reason mouse
// dispatch lives in dispatch.zig).
fn handleMappingNotify(event: *anyopaque) void {
    const e = core.eventCast(*xcb.xcb_mapping_notify_event_t, event);
    if (input.handleMappingNotify(e.request == xcb.XCB_MAPPING_KEYBOARD))
        grabs.grabKeybindings(input.resolvedKeybinds());
}

// O(1) dispatch via a comptime-built table indexed by XCB event type (low 7 bits).
//
// This and eventWindowFor's offset switch below have been proposed for merging
// into one table. They answer different questions -- "is there a handler?" vs
// "where in the struct is the window id?" -- and their code sets are NOT the
// same, in both directions: MAPPING_NOTIFY has a handler and no window field at
// all, while VISIBILITY_NOTIFY, FOCUS_IN/OUT, REPARENT/CREATE/GRAVITY/
// CIRCULATE carry a window and have no handler. Merging them would trade two
// flat lookups for one wider struct over a hot path, to save a handful of
// lines, and would need a sentinel for the offset-less case.
const dispatch_table = blk: {
    var table = [_]?EventHandler{null} ** dispatch_table_len;

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
/// Takes the event's code with the SendEvent bit ALREADY stripped, which
/// routeFor does before calling. A RandR event that arrived via XSendEvent
/// carries bit 7, so testing the raw byte here would miss exactly those and
/// silently disable refresh re-detection.
fn isRandrEvent(code: u8) bool {
    // RandR detection is a display feature, compiled into every tree
    // and armed once at boot; `randrFirstEvent` reports 0 until then,
    // and the `r != 0` test below is what makes this false before
    // arming -- so there is no build flag to consult here.
    const r = hz.randrFirstEvent();
    return (r != 0 and code >= r and code <= r + 1);
}

/// Where a raw event byte routes. Split out of dispatch so the SendEvent-bit
/// rule is testable without an X connection: dispatch needs live core state,
/// but the routing decision that was wrong here was pure.
pub const Route = enum { core, randr, ignore };

/// Routes a RAW event byte. Bit 7 is XCB's SendEvent flag, and it is stripped
/// FIRST, before anything is decided from the code.
///
/// This previously read `if (event_type >= 0x80) return;`, on the reasoning
/// that an EXTENSION event (server-allocated bases at/above 0x80) would
/// otherwise alias onto a core code when masked. The reasoning was sound but
/// the test was not: bit 7 is set by the server on EVERY event delivered via
/// XSendEvent, and core codes never use bit 7. EWMH _NET_WM_STATE is the case
/// that matters -- GDK sends it with XSendEvent and propagate=True precisely
/// so the WM sees the request before the client acts on it, so a browser
/// native-fullscreen request arrives as 33 | 0x80 == 0xA1. That is >= 0x80,
/// so every browser/GTK fullscreen request was discarded here and never
/// reached handleClientMessage: Mod+F worked (hana's own binding calls its
/// fullscreen code directly, with no event involved) while native fullscreen
/// silently did nothing.
///
/// Masking is safe against the aliasing worry because an X client only ever
/// RECEIVES the events it selected. hana selects core events plus its RandR
/// range, so no extension base can arrive to be aliased onto a core code --
/// RandR is matched explicitly, on the masked code.
pub fn routeFor(event_type: u8) Route {
    const code = event_type & masks.core_event_code_mask;
    if (isRandrEvent(code)) return .randr;
    if (code >= dispatch_table.len) return .ignore;
    return if (dispatch_table[code] != null) .core else .ignore;
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

    switch (routeFor(event_type)) {
        .ignore => {},
        // RandR extension events (base and base+1) trigger refresh
        // re-detection here; they sit above the fixed dispatch table.
        .randr => {
            // Re-read the screen size BEFORE the surface path runs, and only
            // when it really changed. Core's cached `Screen` is the
            // pointer the server filled in at setup, so without this a
            // resolution change left the work area, percentage heights and
            // font scaling all sized for the display as it was at startup. The
            // boolean check is what keeps this cheap: a mode change arrives as
            // a BURST of RandR events, and only the first one that moves a
            // dimension pays for the round-trip.
            //
            // DPI is re-derived in the same place, because a different screen
            // size usually means a different physical size too, and every font
            // metric the bar probes is scaled by it. A DPI refresh is a few X
            // resource reads -- no grab -- so it is safe here, unlike a
            // reconcile, which this deliberately does not trigger (see
            // refreshScreenGeometry).
            if (core.refreshScreenGeometry(core.getState().conn)) {
                const cs = core.getState();
                core.setDpi(scale.detectDpi(cs.conn, cs.screen));
            }
            // Pass the raw event: a CRTC-change payload carries the active
            // mode id, letting the probe resolve the rate from its cached
            // mode table with zero XCB round-trips (see hz.handleRandrNotifyEvent).
            hz.handleRandrNotifyEvent(event);
        },
        .core => dispatch_table[event_type & masks.core_event_code_mask].?(event),
    }
}

/// Dispatches an owned event: frees the heap-allocated XCB event after the
/// handler runs. Every dispatch site in handleXcbEvents owns its event
/// (stack- or heap-allocated by XCB), so they all funnel through here.
fn dispatchOwned(event: *anyopaque) void {
    defer std.c.free(event);
    // Opt-in per-window X trace (see xtrace): records the dispatch ORDER of
    // every event for a watched window, which is what a static reading of the
    // WM cannot recover. One branch when disabled, and `watches` is the only
    // thing consulted before anything is formatted.
    const t = eventType(event);
    if (xtrace.enabled()) {
        const win = eventWindowFor(t, event);
        if (xtrace.watches(win)) xtrace.inbound(t, win);
    }
    dispatch(t, event);
}

/// The window an event is about, for the trace's watch filter: event type +
/// raw bytes in, window id out, so the offset table is testable without a
/// live X connection. There is deliberately NO shared offset across event
/// shapes (the switch below spells each group out). Offsets are asserted
/// against xcb/xcb.h in test "eventWindow: offsets match the real xcb
/// structs".
pub fn eventWindowFor(t: u8, event: *anyopaque) u32 {
    const raw: [*]const u8 = @ptrCast(event);
    // Strip the SendEvent bit first: an EWMH _NET_WM_STATE request arrives as
    // 33 | 0x80, and without this every such event read as an unknown type
    // (and reported no_window), which is why a trace aimed at exactly these
    // events showed nothing.
    const code = t & masks.core_event_code_mask;
    // Three shapes, and MappingNotify is a fourth: it has NO window field at
    // all, so it must never match a watch.
    const base: usize = switch (code) {
        // window-carrying, `window` at offset 4
        xcb.XCB_CLIENT_MESSAGE,
        xcb.XCB_PROPERTY_NOTIFY,
        xcb.XCB_EXPOSE,
        xcb.XCB_VISIBILITY_NOTIFY,
        // input, `event` at offset 4 (FocusIn/FocusOut are the odd ones out)
        xcb.XCB_FOCUS_IN,
        xcb.XCB_FOCUS_OUT,
        => 4,
        // input, `event` at offset 12
        xcb.XCB_KEY_PRESS,
        xcb.XCB_KEY_RELEASE,
        xcb.XCB_BUTTON_PRESS,
        xcb.XCB_BUTTON_RELEASE,
        xcb.XCB_MOTION_NOTIFY,
        xcb.XCB_ENTER_NOTIFY,
        xcb.XCB_LEAVE_NOTIFY,
        => 12,
        // window-carrying, `window` at offset 8
        xcb.XCB_CONFIGURE_NOTIFY,
        xcb.XCB_CONFIGURE_REQUEST,
        xcb.XCB_MAP_REQUEST,
        xcb.XCB_UNMAP_NOTIFY,
        xcb.XCB_DESTROY_NOTIFY,
        xcb.XCB_REPARENT_NOTIFY,
        xcb.XCB_CREATE_NOTIFY,
        xcb.XCB_GRAVITY_NOTIFY,
        xcb.XCB_CIRCULATE_NOTIFY,
        => 8,
        // MappingNotify carries only the keyboard mapping, and errors carry a
        // bad resource id. Neither is about a window, so return a value no
        // watch can hold rather than reading whatever bytes happen to be there.
        else => return no_window,
    };
    return @as(u32, raw[base]) | (@as(u32, raw[base + 1]) << 8) |
        (@as(u32, raw[base + 2]) << 16) | (@as(u32, raw[base + 3]) << 24);
}

/// The window id reported for an event that is not about any window
/// (MappingNotify, X errors). `xcb::NONE` so it can never collide with a real
/// id a caller asked to watch -- X window ids are never 0 in practice, and the
/// server hands out no window with id 0.
pub const no_window: u32 = 0;

/// The X11 event type byte (response_type) read off a generic event: the
/// first byte of every XCB event. Shared by the dispatcher (dispatchOwned) and
/// isMotion instead of re-spelling the raw `@as(*u8, @ptrCast(e)).*` read.
inline fn eventType(e: anytype) u8 {
    return @as(*u8, @ptrCast(e)).*;
}

// Re-exec hand-off, driven by lifecycle.consumeReexec() in run(). The sequence
// is fixed: pin the config snapshot, persist the live session FIRST (a failed
// save aborts the hand-off and the WM keeps running on its live connection),
// then drop the X connection so the successor cannot inherit a live
// connection holding the root SubstructureRedirect grab, then execNext
// (which never returns: parent exits immediately, child execs).
fn handleReexec() !void {
    const cs = core.getState();
    log.info("Re-executing new binary", .{});

    const path = try handoff.defaultStatePath(cs.alloc);
    // The path is allocator-owned; execNext never returns so this only
    // ever runs on the error/abort exits below, where the leak would else
    // live for the rest of the process lifetime.
    defer cs.alloc.free(path);
    try handoff.save(cs.alloc, pipeline.model(), path);

    // One record for the whole hand-off. The snapshot is the frozen last-good
    // config, so this re-exec swaps ONLY the binary; a re-exec boot that finds
    // no snapshot (no user config was ever loaded) falls back to the normal
    // search, which reproduces today's fallback-only behavior.
    const exec_handoff = lifecycle.currentHandoff(path, config.reexecSnapshotPathZ()) orelse {
        log.err("Re-exec aborted: executable path unknown", .{});
        return error.ExecutablePathUnknown;
    };

    xcb.xcb_disconnect(cs.conn);
    lifecycle.execNext(exec_handoff);
}

/// One comptime-parameterized drain shared by the batch poll loop and the
/// post-batch queued drain (they differ only in pull function and cap).
/// Each iteration pulls from the caller's `pending` slot first, so a
/// coalesced non-motion stashed there is re-pulled (and charged) on the
/// following iteration, preserving order across batches. The terminating
/// non-motion of a motion run is stashed the same way; when the drain stops
/// on it (cap hit), the caller dispatches the leftover `pending` itself.
/// One stash policy everywhere: both call sites read identically.
fn drainEvents(
    pending: *?*xcb.xcb_generic_event_t,
    conn: core.Connection,
    budget: *usize,
    comptime cap: usize,
    comptime pull: anytype,
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
        collapseMotionRun(&newest, &pause, conn, budget, cap, pull);
        dispatchOwned(newest);
        if (pause) |p| pending.* = p;
    }
}

fn isMotion(e: *xcb.xcb_generic_event_t) bool {
    const code = eventType(e) & masks.core_event_code_mask;
    // RandR on the masked code; see isRandrEvent.
    if (isRandrEvent(code)) return false;
    return code == xcb.XCB_MOTION_NOTIFY;
}

/// Shared motion-run collapse used by both the batch loop and the queued
/// drain. `newest` is the run's newest motion so far (caller-owned; a
/// superseding motion frees it). Reads ahead with `pull` while `budget.*`
/// stays below `cap`, charging each drained motion into `budget` the same way
/// the caller's outer loop charges. The first non-motion ends the run and is
/// stashed to `pause` UNDELIVERED and UNCHARGED -- the drain loop re-pulls it
/// from `pending` and charges it there (or, at the cap, the caller dispatches
/// it as the leftover tail), so `newest`-before-`pause` ordering holds
/// either way. Exactly one charge policy: pull-when-re-pulled.
fn collapseMotionRun(
    newest: anytype,
    pause: *?*xcb.xcb_generic_event_t,
    conn: core.Connection,
    budget: *usize,
    comptime cap: usize,
    comptime pull: anytype,
) void {
    while (budget.* < cap) {
        const next = pull(conn) orelse break;
        if (!isMotion(next)) {
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
    // individual reconciles); its terminating non-motion is stashed to
    // `queued_pending` like the batch drain's -- one stash policy, no
    // with_tail variant.
    var queued_pending: ?*xcb.xcb_generic_event_t = null;
    var extra: usize = 0;
    drainEvents(
        &queued_pending,
        conn,
        &extra,
        max_queued_drain,
        xcb.xcb_poll_for_queued_event,
    );

    // Leftover tail of the queued drain: a terminating non-motion stashed
    // against its cap is delivered here, before post-batch housekeeping --
    // the same tail rule as the batch drain's `pending` dispatch above.
    if (queued_pending) |p| dispatchOwned(p);

    // Drain any spawn pipes that became readable during this event batch.
    // This catches the common case where SIGCHLD and the MapRequest arrive in
    // the same poll wakeup: the spawn pipe's EOF will be readable before
    // SIGCHLD fires, so registerSpawn runs before handleMapRequest needs the
    // spawn queue entry.
    spawn.drainPendingSpawns();

    // The post-batch stages are ORDER-SENSITIVE. They read as an ordered list
    // because they are three statements in order, and each one keeps its reason
    // for sitting where it does.

    // 1. Repaint the bar. Before the focus settle below, because that lift can
    //    generate the EnterNotify this repaint needs to reflect.
    surfaces.updateIfDirty();

    // 2. Focus settle. Must run after the event-draining loop above: any
    //    EnterNotify a tiling reflow generated has to have already been
    //    dispatched (and filtered, since suppression is still active) before
    //    this lifts suppression. See beginTilingOpSettle's doc comment in
    //    focus.zig.
    focus.drainTilingOpSettle();

    // 3. Border sweep, only when a border-relevant fact actually changed during
    //    the batch; a motion/expose-only batch skips the unconditional O(N)
    //    walk. Wire sends are unchanged either way (the sweep is
    //    ledger-dedup'd), so steady-state output is identical. Last, because
    //    it reads the model the two stages above may have moved.
    if (!std.meta.eql(facts_before, core.getState().facts)) window.updateWorkspaceBorders();

    _ = xcb.xcb_flush(conn);
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
    // valid, then one slot per in-flight spawn pipe. The two fixed entries are
    // set once; the spawn slots are rebuilt each round from spawn.readFds,
    // because the set of in-flight spawn pipes changes as commands come and go
    // (a fixed set built at boot never saw post-boot pipes, and the
    // spawn_ready branch below could never fire for them).
    var poll_buf: [2 + spawn.max_read_fds]std.posix.pollfd = undefined;
    var spawn_fds: [spawn.max_read_fds]std.posix.fd_t = undefined;
    poll_buf[fd_xcb] = .{ .fd = x_fd, .events = std.posix.POLL.IN, .revents = 0 };
    poll_buf[fd_signal] = .{ .fd = signal_fd, .events = std.posix.POLL.IN, .revents = 0 };

    // Core owns the timer list; the surfaces hook is one entry in it (see
    // Timers). Built once, outside the loop, because the source set
    // cannot change while the loop runs.
    var source_buf: [1]Source = undefined;
    const n_sources: usize = if (build_options.has_bar) blk: {
        source_buf[0] = surfaces.pollTimeoutMs;
        break :blk 1;
    } else 0;
    const loop_timers: Timers = .{ .sources = source_buf[0..n_sources] };

    while (lifecycle.running.load(.acquire)) {
        // Rebuild the poll set each round so post-boot spawn pipes join it.
        const rds = spawn.readFds(&spawn_fds);
        for (rds, 2..) |fd, i| poll_buf[i] = .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 };
        const fds: []std.posix.pollfd = poll_buf[0 .. 2 + rds.len];

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
            reload.handleConfigReload() catch |err| log.err("Reload failed: {}", .{err});

        if (lifecycle.consumeReexec())
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
        // event dispatch, never mid-batch.
        hz.runPendingRedetect(cs.conn);

        // No `has_bar` guard: `updateClock` is a no-op hook with no surface
        // module compiled in, which is the whole point of the generated
        // `surfaces` table.
        surfaces.updateClock();
    }
}

// ---------------------------------------------------------------------------
// Deadline policy (former timers.zig, merged 2026-10-10): aggregates active
// timer sources to compute the next poll timeout.
// ---------------------------------------------------------------------------

/// One timer source. `null` means "this source wants no wakeup"; a
/// non-negative value is "wake me in this many ms".
///
/// Sources report ABSENCE as null rather than as a negative number, so the
/// distinction between "no timer here" and "a timer in -1 ms" cannot be
/// expressed by accident.
pub const Source = *const fn () ?i32;

/// The loop's registered timer sources, reduced on demand.
///
/// This looks like a list abstraction wrapped around the single entry the loop
/// currently registers (the bar's own deadline), and has been proposed for
/// deletion as such. It is the opposite of redundant: the list IS the policy.
/// The reduce -- consult every source even after one answers, because a later
/// source may want to wake sooner -- is the rule, and a one-entry version could
/// not express it, so the second source would arrive as a branch at the call
/// site, which is the shape this module was created to remove. See
/// timers_test.zig, which exercises the reduce with four sources.
pub const Timers = struct {
    sources: []const Source,

    /// The nearest wakeup across every source, or null when no source wants
    /// one (the loop then blocks until an fd is ready).
    ///
    /// Every source is consulted even once one has answered: a later source
    /// may want to wake sooner, and "sooner" is the whole point. `min` over
    /// the answered ones is the deadline.
    pub fn deadlineMs(self: Timers) ?i32 {
        var nearest: ?i32 = null;
        for (self.sources) |source| {
            const ms = source() orelse continue;
            if (nearest == null or ms < nearest.?) nearest = ms;
        }
        return nearest;
    }
};
