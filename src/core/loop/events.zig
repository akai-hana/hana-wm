//! X event dispatch and main event loop.
//! Drives the WM: dispatches X11 events, OS signals, and config reload; runs
//! the poll/select main loop with timer sources.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const masks = @import("masks");

const log = std.log.scoped(.events);
const trace = @import("trace");
const config = @import("config");
const scale = @import("dpi");
const hz = @import("hz");
// The input subsystem ships as separate modules; this file names the four
// it dispatches to (no facade to re-export them).
const keybinds = @import("keybinds");
const keys = @import("keys");
const mouse = @import("mouse");
const window = @import("window");
const focus = @import("focus");

const pipeline = @import("pipeline");
const reconcile = @import("reconcile");
const requests = @import("requests");
const session = @import("session");
const spawn = @import("spawn");
const build_options = @import("build_options");
// The bar's hook set lives in the `surfaces` composition root (comptime `null`
// when absent), so every `if (build_options.has_bar)` call below compiles away.
const surfaces = @import("surfaces").Surfaces;
const process = @import("process");
// Config reload (the SIGHUP / reload_config transition) lives in
// reload.zig: a lifecycle concern, not per-event path work.
const reload = @import("reload");

const fd_xcb = 0;
const fd_signal = 1;

// Maximum events dispatched per XCB batch before returning to poll, so the
// signal pipe and timer paths get fair scheduling against a chatty client.
// Unmeasured: chosen generous -- 128 events is milliseconds of dispatch work
// and keeps one batch comfortably under a frame; no bench derives it.
const max_events_per_batch: usize = 128;

// Cap for the post-batch drain of XCB's internal event queue (see the drain
// loop in handleXcbEvents); a chatty client cannot fill it beyond this.
// Unmeasured: chosen generous -- XCB's own queue is the real bound, and 256
// drains it faster than the server refills it within one wakeup.
const max_queued_drain: usize = 256;

const EventHandler = *const fn (event: *anyopaque) void;

// The one event table (P2-48): every XCB event code hana knows anything
// about, with its optional handler AND its optional window-field offset.
// The dispatch table and eventWindowFor's offset table are both GENERATED
// from this list at comptime, so adding an event type is a one-line edit
// and the two views can never drift.
//
// The handler and offset sets are NOT the same, in both directions:
// MAPPING_NOTIFY has a handler and no window field at all, while
// VISIBILITY_NOTIFY, FOCUS_OUT, REPARENT/CREATE/GRAVITY/CIRCULATE carry a
// window and have no handler (they are watched by the trace filter but
// deliberately not dispatched). Both are one entry here with one null.
// Merging the two flat lookups into this wider struct is fine: the list is
// comptime data, and the generated tables keep both hot paths O(1).
const EventSpec = struct {
    code: u8,
    handler: ?EventHandler,
    /// Byte offset of the window id in the event struct; null when the
    /// event carries no window (MappingNotify) or has no entry.
    window_offset: ?u8,
};

const event_specs = [_]EventSpec{
    .{ .code = xcb.XCB_ENTER_NOTIFY, .handler = asHandler(window.handleEnterNotify), .window_offset = 12 },
    .{ .code = xcb.XCB_LEAVE_NOTIFY, .handler = asHandler(window.handleLeaveNotify), .window_offset = 12 },
    // P1-09: a client XSetInputFocus-ing its own toplevel is reasserted back
    // to the model's focus (focus.zig's handleFocusIn), so FocusChange no
    // longer lands unhandled. FocusOut is deliberately still unhandled:
    // only the steal (FocusIn) is acted on.
    .{ .code = xcb.XCB_FOCUS_IN, .handler = asHandler(window.handleFocusIn), .window_offset = 4 },
    .{ .code = xcb.XCB_FOCUS_OUT, .handler = null, .window_offset = 4 },

    .{ .code = xcb.XCB_MAP_REQUEST, .handler = asHandler(window.handleMapRequest), .window_offset = 8 },
    .{ .code = xcb.XCB_CONFIGURE_REQUEST, .handler = asHandler(window.handleConfigureRequest), .window_offset = 8 },
    .{ .code = xcb.XCB_UNMAP_NOTIFY, .handler = asHandler(window.handleUnmapNotify), .window_offset = 8 },
    .{ .code = xcb.XCB_DESTROY_NOTIFY, .handler = asHandler(handleDestroyNotify), .window_offset = 8 },
    .{ .code = xcb.XCB_CLIENT_MESSAGE, .handler = asHandler(window.handleClientMessage), .window_offset = 4 },
    .{ .code = xcb.XCB_CONFIGURE_NOTIFY, .handler = asHandler(handleConfigureNotify), .window_offset = 8 },

    .{ .code = xcb.XCB_KEY_PRESS, .handler = asHandler(keys.handleKeyPress), .window_offset = 12 },
    .{ .code = xcb.XCB_KEY_RELEASE, .handler = asHandler(keys.handleKeyRelease), .window_offset = 12 },
    .{ .code = xcb.XCB_BUTTON_PRESS, .handler = asHandler(mouse.handleButtonPress), .window_offset = 12 },
    .{ .code = xcb.XCB_BUTTON_RELEASE, .handler = asHandler(mouse.handleButtonRelease), .window_offset = 12 },
    .{ .code = xcb.XCB_MOTION_NOTIFY, .handler = asHandler(mouse.handleMotionNotify), .window_offset = 12 },
    .{ .code = xcb.XCB_PROPERTY_NOTIFY, .handler = asHandler(handlePropertyNotify), .window_offset = 4 },
    .{ .code = xcb.XCB_EXPOSE, .handler = asHandler(handleExpose), .window_offset = 4 },

    // MappingNotify has a handler and NO window field: the mapping change
    // invalidates the keycode->keysym table, so the regrab runs here.
    .{ .code = xcb.XCB_MAPPING_NOTIFY, .handler = asHandler(handleMappingNotify), .window_offset = null },

    // Offset-only codes (handler = null): these route .ignore but carry a
    // window the trace watch filter reads.
    .{ .code = xcb.XCB_VISIBILITY_NOTIFY, .handler = null, .window_offset = 4 },
    .{ .code = xcb.XCB_REPARENT_NOTIFY, .handler = null, .window_offset = 8 },
    .{ .code = xcb.XCB_CREATE_NOTIFY, .handler = null, .window_offset = 8 },
    .{ .code = xcb.XCB_GRAVITY_NOTIFY, .handler = null, .window_offset = 8 },
    .{ .code = xcb.XCB_CIRCULATE_NOTIFY, .handler = null, .window_offset = 8 },
};

/// Dispatch table size. Must index every XCB core event code hana dispatches;
/// the highest is MappingNotify (34), so 36 leaves headroom. The table lookup
/// is guarded by this bound (dispatch()).
const dispatch_table_len = 36;

// Uniqueness and bounds: a duplicate code would silently shadow the first
// entry in BOTH generated tables, and an out-of-bounds code would panic
// inside the builders below.
comptime {
    for (event_specs, 0..) |a, i| {
        if (a.code >= dispatch_table_len)
            @compileError("event spec code exceeds dispatch_table_len");
        for (event_specs[i + 1 ..]) |b| {
            if (a.code == b.code)
                @compileError("duplicate code in the event table");
        }
    }
}

const dispatch_table = blk: {
    var table = [_]?EventHandler{null} ** dispatch_table_len;
    for (event_specs) |spec| table[spec.code] = spec.handler;
    break :blk table;
};

const window_offset_table = blk: {
    var table = [_]?u8{null} ** dispatch_table_len;
    for (event_specs) |spec| table[spec.code] = spec.window_offset;
    break :blk table;
};

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
    // next reconcile re-parks it (reconcile.markParkedDirty).
    //
    // The managed-window filter is load-bearing, not an optimization: this
    // event fires for every client on the display, including the ones we do
    // not manage, and markParkedDirty already ignores anything not currently
    // parked -- so an unfiltered call would be a wasted reconcile lookup per
    // configure event on the whole session. It also means a managed window's
    // OWN configure (the echo of a park we just sent) sets a flag we then
    // clear, costing one extra park resend per workspace switch and no more.
    if (window.isValidManagedWindow(e.window)) reconcile.markParkedDirty(e.window);
    window.dispatchAll(.notifyConfigureIfPending, .{ e.window, e.width, e.height });
}

// Delegates to window.zig's destroy path. The `onWindowGone` PRE-fire that
// used to live here is gone (P1-40/D28, pinned by P1-19's X-gated test):
// unmanageWindow fires the hook itself before unregistering, so a managed
// destroy fans out EXACTLY once (the count lives in registry.dispatchAll,
// which this delegation and every other path share), and an unmanaged
// window never holds module records for the hook to clear. `pub` so the
// destroy test can drive THIS call site — the one that used to double-fire.
pub fn handleDestroyNotify(event: *anyopaque) void {
    const e = core.eventCast(*xcb.xcb_destroy_notify_event_t, event);
    window.handleDestroyNotify(e);
}

// Adapts keybinds.handleMappingNotify to the EventHandler shape. Only the
// `request` field matters: it says WHICH mapping changed, and only a keyboard
// mapping change invalidates the keycode->keysym table. A keyboard change
// also makes the installed key grabs stale, so the regrab runs HERE, right
// after the rebuild: this is the X-event dispatch table, and deciding that a
// server-side mapping change warrants re-installing the root grabs is a
// decision about that event, not about bind compilation.
fn handleMappingNotify(event: *anyopaque) void {
    const e = core.eventCast(*xcb.xcb_mapping_notify_event_t, event);
    if (keybinds.handleMappingNotify(e.request == xcb.XCB_MAPPING_KEYBOARD))
        keybinds.grabKeybindings(keybinds.resolvedKeybinds());
}

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

/// Where a raw event byte routes, kept separate from dispatch so the
/// SendEvent-bit rule is testable without an X connection: dispatch needs live
/// core state, but the routing decision itself is pure. `.unknown` is a code
/// above every core event hana knows (past the table); `.ignore` is a code
/// hana knows and deliberately does not dispatch (no handler entry).
pub const Route = enum { core, randr, ignore, unknown };

/// Routes a RAW event byte. Bit 7 is XCB's SendEvent flag, and it is stripped
/// FIRST, before anything is decided from the code.
///
/// Rejecting the raw byte instead (`event_type >= 0x80` -> return) would rest
/// on the reasoning that an EXTENSION event (server-allocated bases at/above
/// 0x80) would otherwise alias onto a core code when masked. The reasoning is
/// sound but the test is not: bit 7 is set by the server on EVERY event
/// delivered via XSendEvent, and core codes never use bit 7. EWMH
/// _NET_WM_STATE is the case that matters -- GDK sends it with XSendEvent and
/// propagate=True precisely so the WM sees the request before the client acts
/// on it, so a browser native-fullscreen request arrives as 33 | 0x80 == 0xA1.
/// That is >= 0x80, so such a test would discard every browser/GTK fullscreen
/// request before it reached handleClientMessage: Mod+F would still work
/// (hana's own binding calls its fullscreen code directly, with no event
/// involved) while native fullscreen silently does nothing.
///
/// Masking is safe against the aliasing worry because an X client only ever
/// RECEIVES the events it selected. hana selects core events plus its RandR
/// range, so no extension base can arrive to be aliased onto a core code --
/// RandR is matched explicitly, on the masked code.
pub fn routeFor(event_type: u8) Route {
    const code = masks.coreEventType(event_type);
    if (isRandrEvent(code)) return .randr;
    if (code >= dispatch_table.len) return .unknown;
    return if (dispatch_table[code] != null) .core else .ignore;
}

fn dispatch(event_type: u8, event: *anyopaque) void {
    // Type 0 is an X error pseudo-event produced for a failed *unchecked*
    // request. Nothing else in this codebase subscribes to type-0, so without
    // this branch such errors would be silently dropped, making real-world
    // X11 failures (bad grabs, stale window ids, wrong atoms) undiagnosable.
    if (event_type == 0) {
        const e = core.eventCast(*xcb.xcb_generic_error_t, event);
        // P1-18: the failed request's sequence matches the last outbound
        // sequence recorded for exactly the window it went to (send sites
        // note their cookie at queue time -- see requests.noteSequence), so
        // a hit names the window this otherwise anonymous error belongs to.
        // A miss (older-than-last send to that window, or a non-window
        // resource) falls back to the generic line.
        if (requests.windowForSequence(e.sequence)) |win| {
            log.warn("Unchecked XCB request failed: code={} major={} minor={} resource={x}: last outbound to window {x} @ seq {}", .{ e.error_code, e.major_code, e.minor_code, e.resource_id, win, e.sequence });
        } else {
            log.warn("Unchecked XCB request failed: code={} major={} minor={} resource={x}", .{ e.error_code, e.major_code, e.minor_code, e.resource_id });
        }
        return;
    }

    switch (routeFor(event_type)) {
        .ignore, .unknown => {},
        // RandR extension events (base and base+1) trigger refresh
        // re-detection here; they sit above the fixed dispatch table.
        .randr => {
            // Re-read the screen size BEFORE the surface path runs, and only
            // when it really changed. Core's cached `Screen` is the
            // pointer the server filled in at setup, so without this a
            // resolution change would leave the work area, percentage heights
            // and font scaling all sized for the display as it was at
            // startup. The boolean check is what keeps this cheap: a mode
            // change arrives as a BURST of RandR events, and only the first
            // one that moves a dimension pays for the round-trip.
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
        .core => dispatch_table[masks.coreEventType(event_type)].?(event),
    }
}

/// Dispatches an owned event: frees the heap-allocated XCB event after the
/// handler runs. Every dispatch site in handleXcbEvents owns its event
/// (stack- or heap-allocated by XCB), so they all funnel through here.
fn dispatchOwned(event: *anyopaque) void {
    defer std.c.free(event);
    // Opt-in per-window X trace (see trace): records the dispatch ORDER of
    // every event for a watched window, which is what a static reading of the
    // WM cannot recover. One branch when disabled, and `watches` is the only
    // thing consulted before anything is formatted.
    const t = eventType(event);
    if (trace.enabled()) {
        const win = eventWindowFor(t, event);
        if (trace.watches(win)) trace.inbound(t, win);
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
    // 33 | 0x80, and without this every such event reads as an unknown type
    // (and reports no_window).
    const code = masks.coreEventType(t);
    // Offset comes from the one event table (P2-48): MappingNotify carries no
    // window, errors carry a bad resource id, and codes hana never listed
    // (past the table or only ever dispatched) all read null here -- return a
    // value no watch can hold rather than whatever bytes happen to be there.
    const base: usize = if (code < window_offset_table.len)
        window_offset_table[code] orelse return no_window
    else
        return no_window;
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

// Re-exec hand-off, driven by process.consumeReexec() in run(). The sequence
// is fixed: pin the config snapshot, persist the live session FIRST (a failed
// save aborts the hand-off and the WM keeps running on its live connection),
// then drop the X connection so the successor cannot inherit a live
// connection holding the root SubstructureRedirect grab, then execNext
// (which never returns: parent exits immediately, child execs).
fn handleReexec() !void {
    const cs = core.getState();
    log.info("Re-executing new binary", .{});

    const path = try session.defaultStatePath(cs.alloc);
    // The path is allocator-owned; execNext never returns so this only
    // ever runs on the error/abort exits below, where the leak would else
    // live for the rest of the process lifetime.
    defer cs.alloc.free(path);
    try session.save(cs.alloc, pipeline.state(), path);

    // One record for the whole hand-off. The snapshot is the frozen last-good
    // config, so this re-exec swaps ONLY the binary; a re-exec boot that finds
    // no snapshot (no user config was ever loaded) falls back to the normal
    // search, which reproduces today's fallback-only behavior.
    const exec_handoff = process.currentHandoff(path, config.reexecSnapshotPathZ()) orelse {
        log.err("Re-exec aborted: executable path unknown", .{});
        return error.ExecutablePathUnknown;
    };

    xcb.xcb_disconnect(cs.conn);
    process.execNext(exec_handoff);
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
    const code = masks.coreEventType(eventType(e));
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
/// `pub` for the display-free coalescing test (motion_collapse_test); only
/// drainEvents and that test call it.
pub fn collapseMotionRun(
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
    // to the next batch would put it after the (hundreds of) later events the
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
    // `queued_pending` like the batch drain's -- one stash policy.
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

    // 0. Coalesced property refresh (P1-12). Title/hint PropertyNotifies
    //    marked windows during the batch above; this fetches each marked
    //    window exactly once. Before the bar repaint below, because a title
    //    refresh bumps the window fact that repaint reads.
    window.flushPropertyRefresh();

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

/// Poll-error burst latch (P1-13): a non-INTR poll failure (EMFILE, EINVAL,
/// ...) used to `continue` straight into another failing poll — a tight
/// 100%-CPU spin with an unbounded log.err flood. The latch is pure state so
/// the once-per-burst rule is testable without forcing a real poll failure;
/// run()'s error branch sleeps on EVERY failed iteration (the anti-spin
/// measure) but only logs on the burst's leading edge, and the next SUCCESS
/// resets the latch so a later independent burst logs again.
pub const PollBackoff = struct {
    latched: bool = false,

    /// Records one poll outcome; returns true exactly once per burst — the
    /// first failure after a success (or boot) — so the caller logs only on
    /// the leading edge. Every failure still sleeps; the return value only
    /// gates the log line.
    pub fn note(self: *PollBackoff, failed: bool) bool {
        if (!failed) {
            self.latched = false;
            return false;
        }
        if (self.latched) return false;
        self.latched = true;
        return true;
    }
};

/// One backoff pause after a failed poll. Uses nanosleep directly (the XKB
/// retry path sleeps the same way); resumes on EINTR so a signal doesn't
/// skip the delay — the loop re-polls either way.
fn pollBackoffSleep() void {
    const ns = poll_error_backoff_ms * std.time.ns_per_ms;
    var req = std.os.linux.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    var rem = std.os.linux.timespec{ .sec = 0, .nsec = 0 };
    while (true) {
        const rc = std.os.linux.nanosleep(&req, &rem);
        if (std.posix.errno(rc) != .INTR) break;
        req = rem;
    }
}

/// Backoff delay between failed poll iterations: long enough to break a
/// 100%-CPU spin on a persistent error (EMFILE storm, bad fd), short enough
/// to be invisible when the error clears on the next retry.
const poll_error_backoff_ms = 75;

/// P2-73: whether this poll outcome must drain the X queue in the SAME
/// iteration. True when the xcb fd reported readable (the pre-P2-73 path),
/// OR when the wake was non-X -- timeout, signal, or spawn -- because events
/// that arrived while that wake was being handled would otherwise strand in
/// XCB's queue until the NEXT poll round reported the fd readable again. The
/// ERR/HUP arm is the loop's own break (it never reaches the drain); this
/// predicate is the pure truth table so the decision is testable without a
/// socket.
pub fn shouldDrainX(xcb_revents: i16, signal_revents: i16, spawn_ready: bool, ready: usize) bool {
    const poll_in = std.posix.POLL.IN;
    return (xcb_revents & poll_in) != 0 or
        (signal_revents & poll_in) != 0 or spawn_ready or ready == 0;
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
        process.quit();
        return;
    }
    const signal_fd: std.posix.fd_t = process.readFd();

    // Fixed slots first (x_fd, signal_fd) so the fd_xcb/fd_signal indices stay
    // valid, then one slot per in-flight spawn pipe. The two fixed entries are
    // set once; the spawn slots are rebuilt each round from spawn.readFds,
    // because the set of in-flight spawn pipes changes as commands come and go
    // (a fixed set built at boot would never see post-boot pipes, and the
    // spawn_ready branch below could never fire for them).
    var poll_buf: [2 + spawn.max_read_fds]std.posix.pollfd = undefined;
    var spawn_fds: [spawn.max_read_fds]std.posix.fd_t = undefined;
    var poll_backoff: PollBackoff = .{};
    poll_buf[fd_xcb] = .{ .fd = x_fd, .events = std.posix.POLL.IN, .revents = 0 };
    poll_buf[fd_signal] = .{ .fd = signal_fd, .events = std.posix.POLL.IN, .revents = 0 };

    // Core owns the timer list; the surfaces hook is one entry in it (see
    // Timers). Built once, outside the loop, because the source set
    // cannot change while the loop runs.
    var source_buf: [2]Source = undefined;
    var n_sources: usize = 0;
    // Pending-spawn stuck deadlines are a CORE timer, not a bar one: the
    // sweep inside drainPendingSpawns drops a wedged entry at
    // spawn_timeout_ms, but that sweep only ran when a spawn fd went ready,
    // and on an idle loop no fd ever fires. The deadline itself becomes a
    // poll wakeup (and the timeout wake below re-drains), so 16 wedged
    // entries cannot sit on SpawnQueueFull until unrelated X traffic.
    source_buf[n_sources] = spawn.nextDeadlineMs;
    n_sources += 1;
    if (build_options.has_bar) {
        source_buf[n_sources] = surfaces.pollTimeoutMs;
        n_sources += 1;
    }
    const loop_timers: Timers = .{ .sources = source_buf[0..n_sources] };

    while (process.running.load(.acquire)) {
        // Rebuild the poll set each round so post-boot spawn pipes join it.
        const rds = spawn.readFds(&spawn_fds);
        for (rds, 2..) |fd, i| poll_buf[i] = .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 };
        const fds: []std.posix.pollfd = poll_buf[0 .. 2 + rds.len];

        // No deadline only when no timer source answers: with none the loop
        // blocks until an X event or signal arrives. Sources today are the
        // core spawn-stuck deadline and the bar's one reduced entry (clock
        // segment, prompt cursor blink, carousel marquee). A timeout wake
        // re-drains pending spawns below so a deadline-only wake still gets
        // its sweep.
        const poll_timeout_ms: i32 = loop_timers.deadlineMs() orelse -1;

        const poll_rc = std.os.linux.poll(fds.ptr, fds.len, poll_timeout_ms);
        const ready: usize = switch (std.posix.errno(poll_rc)) {
            .SUCCESS => @intCast(poll_rc),
            .INTR => continue,
            else => |err| {
                if (poll_backoff.note(true)) {
                    log.err("poll error: {s}; backing off {d}ms per failed iteration", .{
                        @errorName(std.posix.unexpectedErrno(err)),
                        poll_error_backoff_ms,
                    });
                }
                pollBackoffSleep();
                continue;
            },
        };
        // A successful poll ends the burst: the next failure logs again.
        _ = poll_backoff.note(false);

        // Drain signals BEFORE the reload/reexec flags are consumed below. A
        // signal byte (SIGUSR1/SIGHUP) dispatches the matching request, which
        // sets a flag AND writes a wake byte into this same pipe; consuming
        // flags first would let the byte be drained-and-discarded in the same
        // poll iteration, leaving the flag set but nothing to wake the loop
        // again (poll sleeps until unrelated X traffic or a timer). Draining
        // first makes the consumption below see the flag it just set.
        if ((fds[fd_signal].revents & std.posix.POLL.IN) != 0)
            process.drainAndDispatch(signal_fd);

        // A spawn pipe with output ready: drain it now instead of waiting for
        // the next X event or SIGCHLD. POLL.ERR/POLL.HUP count too, because a
        // child that exits without writing still has to be read to EOF for
        // finishSpawn to classify the result. Non-blocking by construction.
        // A poll TIMEOUT drains too: that is how a spawn.nextDeadlineMs
        // wakeup delivers its stuck-entry sweep (drain is a no-op on an
        // empty table).
        var spawn_ready = false;
        for (fds[2..]) |pf| {
            if ((pf.revents & (std.posix.POLL.IN | std.posix.POLL.ERR | std.posix.POLL.HUP)) != 0)
                spawn_ready = true;
        }
        if (spawn_ready or poll_rc == 0) spawn.drainPendingSpawns();

        // The reload flag is set by SIGHUP and the reload_config keybinding
        // (proc.reload, which writes a wake byte to the pipe; the byte can be
        // dropped if the pipe is full). Consume it every iteration, BEFORE the
        // ready split: confining it to the ready>0 branch would let a
        // flag-only request stall on timeout wakeups until unrelated X traffic
        // arrives.
        //
        // Config reload is consumed BEFORE re-exec: a chained bind
        // (["reload_config", "reload_hana"]) sets both flags in one dispatch,
        // and reload_config must apply + validate (and refresh the re-exec
        // snapshot) before the successor boots from that snapshot. A reload
        // that fails keeps the last-good snapshot, so the re-exec still lands
        // on the previously live config.
        if (process.consumeReload())
            reload.handleConfigReload() catch |err| log.err("Reload failed: {}", .{err});

        if (process.consumeReexec())
            handleReexec() catch |err| log.err("Re-exec failed: {}", .{err});

        if (ready == 0 and poll_timeout_ms >= 0) {
            surfaces.onPollWakeup();
            _ = xcb.xcb_flush(cs.conn);
        } else if ((fds[fd_xcb].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP)) != 0) {
            log.err("X11 connection error, shutting down", .{});
            break;
        }

        // P2-73: drain X events on EVERY wake whose handling could have let
        // events queue behind it -- not only when the poll reported the xcb
        // fd readable. A signal/spawn/timeout wake (reload, spawn sweep,
        // timer) can take long enough that X events arrive mid-handling;
        // without this they strand in XCB's queue until the NEXT poll round.
        // handleXcbEvents pulls via xcb_poll_for_event (nonblocking): an
        // idle socket is a null return, so the extra drain on a non-X-only
        // wake costs one failed read at most.
        if (shouldDrainX(fds[fd_xcb].revents, fds[fd_signal].revents, spawn_ready, ready))
            handleXcbEvents();

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

/// Deadline policy: aggregates active timer sources to compute the next poll
/// timeout.
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
/// currently registers (the bar's own deadline). It is the opposite of
/// redundant: the list IS the policy.
/// The reduce -- consult every source even after one answers, because a later
/// source may want to wake sooner -- is the rule, and a one-entry version could
/// not express it, so the second source would arrive as a branch at the call
/// site, which is the shape this module exists to avoid. See
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
