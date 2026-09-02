//! X event dispatch and main event loop.
//! Handles X events, OS signals, and config reload, driving the WM's main loop.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const utils = @import("utils");
const constants = @import("constants");
const masks = @import("masks");

const debug = @import("debug");
const config = @import("config");
const input = @import("input");
const window = @import("window");
const focus = @import("focus");

const refresh = @import("refresh");
const signals = @import("signals");
const pipeline = @import("pipeline");
const actions = @import("actions");
const restart = @import("restart");
const persist = @import("persist");
const build_options = @import("build_options");
// Core's reach into the compiled-in chrome surface (the bar) lives in the
// `surfaces` composition root, not here. `surfaces` is the bar's hook set
// when present, and the comptime `null` type when absent, so every
// `if (build_options.has_bar)` call below compiles away. This file never
// names the bar module directly. The `build_options` import stays for the
// `has_bar` compile-time guards used below.
const surfaces = @import("plugins").Surfaces;
// Window sub-system event hooks (pending bar hide/show, destroy handling)
// are reached through the build-generated `window_modules` registry (never
// by naming a sub-system module directly), the same seam discipline as
// `surfaces` above. `window_mods` is the auto-discovered `[N]WindowModule`
// array; absent modules aren't in it, so the uniform loops below no-op for a
// tree without a given sub-system.
const window_mods = @import("window_modules").modules;

const fd_xcb = 0;
const fd_signal = 1;

// Maximum events dispatched per XCB batch before returning to poll, so the
// signal pipe and timer paths get fair scheduling against a chatty client.
const max_events_per_batch: usize = 128;

// Module-level carry for the non-motion event stashed while coalescing the
// LAST batch's motions but not yet dispatched when the batch cap hit. It is
// owned here (NOT in a stack-local `pending`) so it survives the gap between
// one handleXcbEvents return and the next poll round; a stack-local `pending`
// would have to free it at cap exit, silently DROPPING a real event (e.g. a
// KeyPress or ConfigureNotify) that had already been charged against—and
// skipped within—that batch. Sizing is exact: at most one event is ever
// stashed (motion coalescing holds only the newest motion and one non-motion).
var stashed_event: ?*xcb.xcb_generic_event_t = null;

const EventHandler = *const fn (event: *anyopaque) void;

// Casts a `fn(*T) void` event handler to the generic `EventHandler` pointer
// type via @ptrCast. Safe only because every registered handler takes a
// single pointer argument and returns void, matching EventHandler's shape
// exactly; the check below enforces that at comptime so a handler with the
// wrong signature fails to build instead of miscompiling through the cast.
inline fn asHandler(comptime f: anytype) EventHandler {
    const info = @typeInfo(@TypeOf(f)).@"fn";
    if (info.params.len != 1)
        @compileError("event handler must take exactly one parameter, got " ++ @typeName(@TypeOf(f)));
    if (info.params[0].type == null or @typeInfo(info.params[0].type.?) != .pointer)
        @compileError("event handler's parameter must be a single-item pointer, got " ++ @typeName(@TypeOf(f)));
    if (info.return_type != void)
        @compileError("event handler must return void, got " ++ @typeName(@TypeOf(f)));
    return @ptrCast(&f);
}

inline fn eventCast(comptime T: type, event: *anyopaque) T {
    return @ptrCast(@alignCast(event));
}

fn handleExpose(event: *anyopaque) void {
    const e = eventCast(*xcb.xcb_expose_event_t, event);
    if (build_options.has_bar) surfaces.handleExpose(e);
}

fn handlePropertyNotify(event: *anyopaque) void {
    const e = eventCast(*xcb.xcb_property_notify_event_t, event);
    if (build_options.has_bar) surfaces.handlePropertyNotify(e);
    window.handlePropertyNotify(e);
}

// Routes ConfigureNotify to the fullscreen deferred-bar-hide/show logic.
fn handleConfigureNotify(event: *anyopaque) void {
    const e = eventCast(*xcb.xcb_configure_notify_event_t, event);
    for (window_mods) |m| if (m.notifyConfigureIfPending) |f| f(e.window, e.width, e.height);
}

// Notifies fullscreen of the destroyed window before delegating to window.zig.
// This clears any pending deferred bar-show for a window that exits fullscreen
// and is then destroyed before it can send a ConfigureNotify.
fn handleDestroyNotify(event: *anyopaque) void {
    const e = eventCast(*xcb.xcb_destroy_notify_event_t, event);
    for (window_mods) |m| if (m.onWindowGone) |f| f(e.window);
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
    var table = [_]?EventHandler{null} ** constants.Limits.event_dispatch_table;

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
    table[xcb.XCB_FOCUS_IN] = asHandler(focus.handleFocusIn);
    table[xcb.XCB_PROPERTY_NOTIFY] = asHandler(handlePropertyNotify);

    table[xcb.XCB_EXPOSE] = asHandler(handleExpose);

    table[xcb.XCB_CONFIGURE_NOTIFY] = asHandler(handleConfigureNotify);

    break :blk table;
};

fn dispatch(event_type: u8, event: *anyopaque) void {
    // Type 0 is an X error pseudo-event produced for a failed *unchecked*
    // request. Nothing else in this codebase subscribes to type-0, so without
    // this branch such errors would be silently dropped, making real-world
    // X11 failures (bad grabs, stale window ids, wrong atoms) undiagnosable.
    if (event_type == 0) {
        const e = eventCast(*xcb.xcb_generic_error_t, event);
        debug.warn("Unchecked XCB request failed: code={} major={} minor={} resource={x}", .{
            e.error_code, e.major_code, e.minor_code, e.resource_id,
        });
        return;
    }

    // RandR extension events (base and base+1): screen/CRTC/output change
    // notifications. Bar render pacing must track monitor
    // re-configuration, so any of them triggers re-detection. Extension events
    // sit above the fixed dispatch table and would otherwise be dropped by the
    // bounds guard below.
    //
    // The range test uses the RAW type byte, BEFORE the 0x7F mask below: the
    // synthetic-event bit is only meaningful for core events, and an extension
    // base can legitimately be >= 0x80 (the server allocates bases at/after
    // 0x80 precisely to leave bit 7 free for SendEvent on core codes). Masking
    // first would alias such a base onto a low core code and break the test,
    // silently disabling refresh re-detection (and misrouting the event).
    const randr_first = refresh.randrFirstEvent();
    if (randr_first != 0 and event_type >= randr_first and event_type <= randr_first + 1) {
        refresh.handleRandrNotifyEvent(core.getState().conn);
        return;
    }

    const idx = event_type & 0x7F; // strip XCB synthetic-event bit

    // Guard the fixed-size table: extension events live above XCB_GE_GENERIC
    // and would index out of bounds. hana only selects core events today, but
    // the moment anyone subscribes to an extension this would become a
    // memory-safety bug; cheap insurance.
    if (idx >= dispatch_table.len) return;
    if (dispatch_table[idx]) |handler| handler(event);
}

const CookieEntry = struct { cookie: xcb.xcb_void_cookie_t, keycode: u8 };

fn fillGrabCookies(cookies: []CookieEntry) usize {
    var n: usize = 0;
    const cs = core.getState();
    for (cs.config.keybindings.items) |kb| {
        const keycode = kb.keycode orelse continue;

        // Check once per keybinding that the full lock-modifier set fits.
        // Avoids a per-lock branch and prevents partial grabs if the buffer is nearly full.
        if (n + masks.lock_modifiers.len > cookies.len) {
            debug.warn("Too many keybindings. Increase max_keybind_cookies (currently {})", .{constants.Limits.max_keybind_cookies});
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
            debug.warn("Failed to grab keycode: {}", .{entry.keycode});
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

    var cookies: [constants.Limits.max_keybind_cookies]CookieEntry = undefined;
    const n = fillGrabCookies(&cookies);

    const failed = checkGrabCookies(cookies[0..n]);
    if (failed > 0) debug.warn("{} keybinding(s) failed to grab", .{failed});

    _ = xcb.xcb_flush(cs.conn);
}

// Loads and validates a new config, then applies it atomically via pointer
// swap. On failure the old config remains active.
//
// Ordering is load-bearing:
//   1. Keybind resolution and DPI scaling run pre-swap on the new config.
//   2. The swap precedes subsystem reloads (reloadBorders / reloadConfig /
//      surfaces.onReload) so they rebuild from the NEW config. (The old ordering kept
//      stale settings, then freed string slices the new bar had shallow-copied;
//      a use-after-free on the next draw.)
//   3. grabKeybindings() runs post-swap because fillGrabCookies() reads the
//      live config.
//   4. errdefer frees the heap-allocated new config if anything fails pre-swap.
//      Post-swap all calls are infallible, so no errdefer is needed.
fn handleConfigReload() !void {
    debug.info("Reload requested", .{});
    const cs = core.getState();

    const new_config = config.loadConfigDefault(cs.alloc) catch |err| {
        debug.err("Failed to load: {}, keeping old", .{err});
        return err;
    };
    // Heap-allocate so the swap is a pointer exchange, not a by-value copy.
    // errdefer frees the allocation if anything fails before the swap.
    const new_ptr = try cs.alloc.create(@TypeOf(new_config));
    new_ptr.* = new_config;
    errdefer new_ptr.deinit(cs.alloc);

    try config.validate(new_ptr);
    const xkb_state = input.getXkbState() orelse {
        // XKB was torn down (deinit/init window during a reload); reusing the
        // old config here prevents the rebuilt keybind resolver / finalize
        // from running on stale XKB. Free the not-yet-live allocation that
        // the errdefer above owned.
        debug.warn("Config reload before XKB init; keeping old config", .{});
        new_ptr.deinit(cs.alloc);
        return;
    };
    new_ptr.keybind_resolver.build(new_ptr.keybindings.items, xkb_state, cs.alloc);
    config.finalizeConfig(new_ptr, cs.screen);

    // Swap pointers: new config becomes live, old config is isolated.
    const old_ptr = cs.config;
    cs.config = new_ptr;

    if (build_options.has_bar) surfaces.onReload();
    actions.applyConfigReload();
    // Borders sweep AFTER applyConfigReload: its reconcile rebuilds geometry,
    // and sweeping first would send every border twice -- once here, once
    // again deduped against fresh state. Sweeping last lets borders.apply
    // dedup against entries the reconcile just wrote.
    window.reloadBorders();

    // Free the displaced old config after subsystem reloads have moved on.
    old_ptr.deinit(cs.alloc);

    grabKeybindings();

    // Rebuild after the swap so borrowed key slices point into the new config's memory.
    window.buildRulesMap();

    debug.info("Reload complete", .{});
}

// Re-exec hand-off, driven by restart.consumeReexec() in run(). The sequence
// is fixed: resolve the exec path, persist the live session FIRST (a failed
// save aborts the hand-off and the WM keeps running on its live connection),
// then drop the X connection so the successor cannot inherit a live
// connection holding the root SubstructureRedirect grab, then execNext
// (which never returns: parent exits immediately, child execs).
fn handleReexec() !void {
    const cs = core.getState();
    const self_path = restart.selfPath() orelse {
        debug.err("Re-exec aborted: executable path unknown", .{});
        return error.ExecutablePathUnknown;
    };
    debug.info("Re-executing new binary", .{});

    const path = try persist.defaultStatePath(cs.alloc);
    try persist.save(cs.alloc, pipeline.model(), path);

    xcb.xcb_disconnect(cs.conn);
    restart.execNext(self_path, path);
}

// Returns a pending stashed event if one exists, otherwise polls for the next
// XCB event. `pending` holds the non-motion event stashed during motion
// coalescing so ordering is preserved across batch iterations.
fn takeEvent(pending: *?*xcb.xcb_generic_event_t, conn: core.Connection) ?*xcb.xcb_generic_event_t {
    if (pending.*) |p| {
        pending.* = null;
        return p;
    }
    // Carry from a prior cap-exit batch first, so a stashed event that was
    // charged against the previous batch's budget is not lost.
    if (stashed_event) |p| {
        stashed_event = null;
        return p;
    }
    return xcb.xcb_poll_for_event(conn);
}

fn isMotion(e: *xcb.xcb_generic_event_t) bool {
    const t = @as(*u8, @ptrCast(e)).*;
    // Same masking hazard as dispatch: a RandR extension base >= 0x80
    // (e.g. 0x85 -> 0x85 & 0x7f == 5) would alias onto MOTION_NOTIFY and some
    // RandR event would be reclassified as a coalesceable motion. Exclude the
    // RandR window (raw compare) before stripping the send_event bit.
    const r = refresh.randrFirstEvent();
    if (r != 0 and t >= r and t <= r + 1) return false;
    return (t & 0x7f) == xcb.XCB_MOTION_NOTIFY;
}

// Drains pending XCB events for this batch, then runs post-batch housekeeping.
fn handleXcbEvents() void {
    const conn = core.getState().conn;

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
    // batch cap via takeEvent) so ordering is preserved.
    var pending: ?*xcb.xcb_generic_event_t = null;

    var dispatched: usize = 0;
    while (dispatched < max_events_per_batch) : (dispatched += 1) {
        var event = takeEvent(&pending, conn) orelse break;
        defer std.c.free(event);
        var coalesced: usize = 0;
        if (isMotion(event)) {
            // Coalesce the run, but charge every drained motion against the
            // batch budget: an endless motion stream must not starve the
            // signal pipe and timer paths the cap exists to protect.
            while (dispatched + coalesced < max_events_per_batch) {
                const next = xcb.xcb_poll_for_event(conn) orelse break;
                if (!isMotion(next)) {
                    pending = next; // dispatched on a later iteration
                    break;
                }
                std.c.free(event);
                event = next; // keep only the newest motion of the run
                coalesced += 1;
            }
            dispatched += coalesced;
        }
        dispatch(@as(*u8, @ptrCast(event)).*, event);
    }

    // A cap exit can leave a non-motion event held in `pending` (stashed
    // during motion coalescing). It was already skipped this batch, so carry
    // it to the next batch's `takeEvent` rather than dropping it — it's a
    // real event that the batch budget had already accounted for. On the
    // normal (socket-empty) exit path `pending` is always null and nothing is
    // carried.
    if (pending) |p| stashed_event = p;

    // Drain any spawn pipes that became readable during this event batch.
    // This catches the common case where SIGCHLD and the MapRequest arrive in
    // the same poll wakeup: the spawn pipe's EOF will be readable before
    // SIGCHLD fires, so registerSpawn runs before handleMapRequest needs the
    // spawn queue entry.
    @import("spawn").drainPendingSpawns();

    if (build_options.has_bar) surfaces.updateIfDirty() catch |err| debug.err("Bar post-batch update failed: {}", .{err});
    focus.drainPendingConfirm();
    focus.drainPointerSync();
    // Must run after the event-draining loop above: any EnterNotify a tiling
    // reflow generated has to have already been dispatched (and filtered,
    // since suppression is still active) before this lifts suppression.
    // See beginTilingOpSettle's doc comment in focus.zig.
    focus.drainTilingOpSettle();
    window.updateWorkspaceBordersIfNeeded();

    _ = xcb.xcb_flush(conn);
}

pub fn run() !void {
    const cs = core.getState();
    const x_fd: std.posix.fd_t = xcb.xcb_get_file_descriptor(cs.conn);
    const signal_fd: std.posix.fd_t = signals.readFd();

    var fds = [_]std.posix.pollfd{
        .{ .fd = x_fd, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = signal_fd, .events = std.posix.POLL.IN, .revents = 0 },
    };

    while (utils.running.load(.acquire)) {
        // No built-in deadline: with no timer sources the loop blocks until
        // an X event or signal arrives. Timer sources (clock segment, prompt
        // cursor blink, carousel marquee) contribute deadlines exclusively
        // through surfaces.pollTimeoutMs().
        var poll_timeout_ms: i32 = -1;
        var cursor_is_blinking = false;
        if (build_options.has_bar) {
            const ms = surfaces.pollTimeoutMs();
            if (ms >= 0) {
                cursor_is_blinking = true;
                poll_timeout_ms = ms;
            }
        }

        const poll_rc = std.os.linux.poll(&fds, fds.len, poll_timeout_ms);
        const ready: usize = switch (std.posix.errno(poll_rc)) {
            .SUCCESS => @intCast(poll_rc),
            .INTR => continue,
            else => |err| {
                debug.err("poll error: {s}", .{@errorName(std.posix.unexpectedErrno(err))});
                continue;
            },
        };

        // Drain signals BEFORE the reload/reexec flags are consumed below. A
        // signal byte (SIGUSR1/SIGHUP) dispatches requestReload, which sets a
        // flag AND writes a wake byte into this same pipe; consuming flags
        // first let the byte be drained-and-discarded in the same poll
        // iteration, leaving the flag set but nothing to wake the loop again
        // (poll sleeps until unrelated X traffic or a timer). Draining first
        // makes the consumption below see the flag it just set.
        if ((fds[fd_signal].revents & std.posix.POLL.IN) != 0)
            signals.drainAndDispatch(signal_fd);

        // The reload flag is also set directly by the reload_config keybinding
        // (which writes a wake byte to the pipe, but the byte can be dropped if
        // the pipe is full). Consume it every iteration, BEFORE the ready split:
        // confining it to the ready>0 branch let a flag-only request stall on
        // timeout wakeups until unrelated X traffic arrived.
        //
        // Re-exec supersedes config reload: consumed first so a request that
        // decided "binary changed" turns into the process hand-off instead of
        // a config-only reload (the request paths are mutually exclusive, but
        // a hand-off must never be deferred behind an in-flight reload).
        if (restart.consumeReexec())
            handleReexec() catch |err| debug.err("Re-exec failed: {}", .{err});

        if (utils.consumeReload())
            handleConfigReload() catch |err| debug.err("Reload failed: {}", .{err});

        if (ready == 0 and cursor_is_blinking) {
            if (build_options.has_bar) surfaces.onPollWakeup();
            _ = xcb.xcb_flush(cs.conn);
        } else if ((fds[fd_xcb].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP)) != 0) {
            debug.err("X11 connection error, shutting down", .{});
            break;
        } else if ((fds[fd_xcb].revents & std.posix.POLL.IN) != 0) {
            handleXcbEvents();
        }

        // Run any refresh-rate re-detection deferred by handleRandrNotifyEvent.
        // It performs synchronous XCB round-trips, so it must run here, outside
        // event dispatch, never mid-batch.
        refresh.runPendingRedetect(cs.conn);

        if (build_options.has_bar) _ = surfaces.updateClock(); // return value reserved, currently unused
    }
}
