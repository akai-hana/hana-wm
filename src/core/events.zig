//! X event dispatch and main event loop
//! Handles X events, OS signals, and config reload, driving the WM's main loop.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const utils = @import("utils");
const constants = @import("constants");

const debug = @import("debug");
const config = @import("config");
const input = @import("input");
const window = @import("window");
const focus = @import("focus");

const plugins = @import("plugins");
const clock = @import("clock");
const fullscreen = @import("fullscreen");
const refresh_rate = @import("refresh_rate");
const signals = @import("signals");
const build_options = @import("build_options");

// Indices into the poll fd array.
const FD_XCB = 0;
const FD_SIGNAL = 1;

/// Maximum events dispatched per XCB batch before returning to poll, so the
/// signal pipe and timer paths get fair scheduling against a chatty client.
const MAX_EVENTS_PER_BATCH: usize = 128;

// Dispatch table

const EventHandler = *const fn (event: *anyopaque) void;

/// Casts a `fn(*T) void` event handler to the generic `EventHandler` pointer
/// type via @ptrCast. Safe only because every registered handler takes a
/// single pointer argument and returns void, matching EventHandler's shape
/// exactly; the check below enforces that at comptime so a handler with the
/// wrong signature fails to build instead of miscompiling through the cast.
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

/// Fans out expose events to all plugins that handle them.
fn dispatchExpose(event: *anyopaque) void {
    const e = eventCast(*xcb.xcb_expose_event_t, event);
    inline for (plugins.list[0..plugins.count]) |p| {
        if (p.on_expose) |f| f(e);
    }
}

/// Fans out PropertyNotify to plugins and window.
fn handlePropertyNotify(event: *anyopaque) void {
    const e = eventCast(*xcb.xcb_property_notify_event_t, event);
    inline for (plugins.list[0..plugins.count]) |p| {
        if (p.on_property_notify) |f| f(e);
    }
    window.handlePropertyNotify(e);
}

/// Routes ConfigureNotify to the fullscreen deferred-bar-hide/show logic.
fn handleConfigureNotify(event: *anyopaque) void {
    const e = eventCast(*xcb.xcb_configure_notify_event_t, event);
    fullscreen.notifyConfigureIfPending(e.window, e.width, e.height);
}

/// Notifies fullscreen of the destroyed window before delegating to window.zig.
/// This clears any pending deferred bar-show for a window that exits fullscreen
/// and is then destroyed before it can send a ConfigureNotify.
fn handleDestroyNotify(event: *anyopaque) void {
    const e = eventCast(*xcb.xcb_destroy_notify_event_t, event);
    fullscreen.onWindowGone(e.window);
    window.handleDestroyNotify(e);
}

/// Adapts input.handleMappingNotify to the EventHandler shape. The keymap
/// rebuild it triggers doesn't consult any MappingNotify fields, so the
/// event pointer is discarded.
fn handleMappingNotify(event: *anyopaque) void {
    _ = event;
    input.handleMappingNotify();
}

/// O(1) dispatch via a comptime-built table indexed by XCB event type (low 7 bits).
const dispatch_table = blk: {
    var table = [_]?EventHandler{null} ** constants.Limits.EVENT_DISPATCH_TABLE;

    table[xcb.XCB_ENTER_NOTIFY] = asHandler(window.handleEnterNotify);
    table[xcb.XCB_LEAVE_NOTIFY] = asHandler(window.handleLeaveNotify);

    table[xcb.XCB_MAP_REQUEST] = asHandler(window.handleMapRequest);
    table[xcb.XCB_CONFIGURE_REQUEST] = asHandler(window.handleConfigureRequest);
    table[xcb.XCB_UNMAP_NOTIFY] = asHandler(window.handleUnmapNotify);
    table[xcb.XCB_DESTROY_NOTIFY] = asHandler(handleDestroyNotify);
    table[xcb.XCB_CLIENT_MESSAGE] = asHandler(window.handleClientMessage);

    table[xcb.XCB_KEY_PRESS] = asHandler(input.handleKeyPress);
    table[xcb.XCB_MAPPING_NOTIFY] = asHandler(handleMappingNotify);
    table[xcb.XCB_BUTTON_PRESS] = asHandler(input.handleButtonPress);
    table[xcb.XCB_BUTTON_RELEASE] = asHandler(input.handleButtonRelease);
    table[xcb.XCB_MOTION_NOTIFY] = asHandler(input.handleMotionNotify);
    table[xcb.XCB_FOCUS_IN] = asHandler(focus.handleFocusIn);
    table[xcb.XCB_PROPERTY_NOTIFY] = asHandler(handlePropertyNotify);

    table[xcb.XCB_EXPOSE] = asHandler(dispatchExpose);

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
    const idx = event_type & 0x7F; // strip XCB synthetic-event bit

    // RandR extension events (base and base+1): screen/CRTC/output change
    // notifications. The carousel's refresh-rate cadence must track monitor
    // re-configuration, so any of them triggers re-detection. Extension events
    // sit above the fixed dispatch table and would otherwise be dropped by the
    // bounds guard below.
    const randr_first = refresh_rate.randrFirstEvent();
    if (randr_first != 0 and idx >= randr_first and idx <= randr_first + 1) {
        refresh_rate.handleRandrNotifyEvent(core.getState().conn);
        return;
    }

    // Guard the fixed-size table: extension events live above XCB_GE_GENERIC
    // and would index out of bounds. hana only selects core events today, but
    // the moment anyone subscribes to an extension this would become a
    // memory-safety bug; cheap insurance.
    if (idx >= dispatch_table.len) return;
    if (dispatch_table[idx]) |handler| handler(event);
}

// Keybindings

const CookieEntry = struct { cookie: xcb.xcb_void_cookie_t, keycode: u8 };

/// Fills `cookies` with one grab request per (keybinding x lock modifier) pair.
/// Returns the number of entries written.
fn fillGrabCookies(cookies: []CookieEntry) usize {
    var n: usize = 0;
    const cs = core.getState();
    for (cs.config.keybindings.items) |kb| {
        const keycode = kb.keycode orelse continue;

        // Check once per keybinding that the full lock-modifier set fits.
        // Avoids a per-lock branch and prevents partial grabs if the buffer is nearly full.
        if (n + constants.LOCK_MODIFIERS.len > cookies.len) {
            debug.warn("Too many keybindings. Increase MAX_KEYBIND_COOKIES (currently {})", .{constants.Limits.MAX_KEYBIND_COOKIES});
            break;
        }

        for (constants.LOCK_MODIFIERS) |lock| {
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

/// Checks each cookie for an XCB error. Returns the number of failures.
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

/// Ungrabs all keys, then re-grabs every configured keybinding across all lock modifier combinations.
/// Fires all grab cookies before reading any reply to reduce round-trips.
pub fn grabKeybindings() void {
    const cs = core.getState();
    _ = xcb.xcb_ungrab_key(cs.conn, xcb.XCB_GRAB_ANY, cs.root, xcb.XCB_MOD_MASK_ANY);

    var cookies: [constants.Limits.MAX_KEYBIND_COOKIES]CookieEntry = undefined;
    const n = fillGrabCookies(&cookies);

    const failed = checkGrabCookies(cookies[0..n]);
    if (failed > 0) debug.warn("{} keybinding(s) failed to grab", .{failed});

    _ = xcb.xcb_flush(cs.conn);
}

// Config reload

/// Loads and validates a new config, then applies it atomically. On failure
/// the old config remains active.
///
/// Ordering is load-bearing:
///   1. Keybind resolution and DPI scaling run pre-swap on `new_config`.
///   2. The swap precedes the subsystem reloads (reloadBorders / reloadConfig /
///      bar.reload) so they rebuild from the NEW config. (The old ordering kept
///      stale settings, then old_config.deinit() freed string slices the new bar
///      had shallow-copied; a use-after-free on the next draw.)
///   3. grabKeybindings() runs post-swap because fillGrabCookies() reads the
///      live config.
///   4. `committed` flips the errdefer: pre-swap failure frees new_config;
///      post-swap failure keeps it and frees the displaced old_config. (Every
///      post-swap call is void today, so this is latent-but-safe.)
///   5. applyCarouselSettings() runs post-swap so a rejected reload never leaks
///      staged carousel settings.
fn handleConfigReload() !void {
    debug.info("Reload requested", .{});
    const cs = core.getState();

    var new_config = config.loadConfigDefault(cs.alloc) catch |err| {
        debug.err("Failed to load: {}, keeping old", .{err});
        return err;
    };
    var old_config = cs.config;
    var committed = false;
    errdefer {
        if (committed) {
            old_config.deinit(cs.alloc);
        } else {
            new_config.deinit(cs.alloc);
        }
    }

    try config.validate(&new_config);
    new_config.keybind_resolver.build(new_config.keybindings.items, input.getXkbState(), cs.alloc);
    config.finalizeConfig(&new_config, cs.screen);

    cs.config = new_config;
    committed = true;

    window.reloadBorders();
    plugins.fanOut("reload", .{});

    old_config.deinit(cs.alloc);

    grabKeybindings();

    // Rebuild after the swap so borrowed key slices point into the new config's memory.
    window.buildRulesMap();

    config.applyCarouselSettings(&new_config);

    debug.info("Reload complete", .{});
}

// Event loop

/// Drains pending XCB events for this batch, then runs post-batch housekeeping.
fn handleXcbEvents() void {
    const conn = core.getState().conn;

    // Cap the number of events dispatched per batch so a chatty client
    // flooding PropertyNotify/ConfigureNotify can't starve the signal pipe and
    // timer paths (clock, cursor blink) indefinitely. Unread events stay in the
    // socket buffer and the fd stays readable, so they're handled on the next
    // poll round.
    for (0..MAX_EVENTS_PER_BATCH) |_| {
        const event = xcb.xcb_poll_for_event(conn) orelse break;
        defer std.c.free(event);
        dispatch(@as(*u8, @ptrCast(event)).*, event);
    }

    // Drain any spawn pipes that became readable during this event batch.
    // This catches the common case where SIGCHLD and the MapRequest arrive in
    // the same poll wakeup: the spawn pipe's EOF will be readable before
    // SIGCHLD fires, so registerSpawn runs before handleMapRequest needs the
    // spawn queue entry.
    input.drainPendingSpawns();

    // Post-batch housekeeping: fan out to all plugins
    inline for (plugins.list[0..plugins.count]) |p| {
        if (p.post_batch) |f| f() catch |err| debug.err("Plugin post_batch failed: {}", .{err});
    }
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
    const x_fd: std.posix.fd_t = xcb.xcb_get_file_descriptor(core.getState().conn);
    const signal_fd: std.posix.fd_t = signals.readFd();

    var fds = [_]std.posix.pollfd{
        .{ .fd = x_fd, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = signal_fd, .events = std.posix.POLL.IN, .revents = 0 },
    };

    while (utils.running.load(.acquire)) {
        // Compute poll timeout from plugins that have a poll_timeout_ms hook
        var poll_timeout_ms: i32 = @intCast(clock.nextTickWaitMs());
        var cursor_is_blinking = false;
        inline for (plugins.list[0..plugins.count]) |p| {
            if (p.poll_timeout_ms) |f| {
                const ms = f();
                if (ms >= 0) {
                    cursor_is_blinking = true;
                    poll_timeout_ms = if (poll_timeout_ms < 0) ms else @min(poll_timeout_ms, ms);
                }
            }
        }
        if (poll_timeout_ms < 0) poll_timeout_ms = @intCast(clock.nextTickWaitMs());

        const poll_rc = std.os.linux.poll(&fds, fds.len, poll_timeout_ms);
        const ready: usize = switch (std.posix.errno(poll_rc)) {
            .SUCCESS => @intCast(poll_rc),
            .INTR => continue,
            else => |err| {
                debug.err("poll error: {s}", .{@errorName(std.posix.unexpectedErrno(err))});
                break;
            },
        };

        if (ready == 0) {
            if (cursor_is_blinking) {
                inline for (plugins.list[0..plugins.count]) |p| {
                    if (p.on_poll_wakeup) |f| f();
                }
                _ = xcb.xcb_flush(core.getState().conn);
            }
        } else if ((fds[FD_XCB].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP)) != 0) {
            debug.err("X11 connection error, shutting down", .{});
            break;
        } else {
            if ((fds[FD_XCB].revents & std.posix.POLL.IN) != 0) handleXcbEvents();

            if ((fds[FD_SIGNAL].revents & std.posix.POLL.IN) != 0)
                signals.drainAndDispatch(signal_fd);

            // The reload flag is also set directly by the reload_config keybinding
            // (which writes a wake byte to the pipe, but the byte can be dropped if
            // the pipe is full). Consume it every iteration so that path can never
            // be lost; a flag-only request is picked up on the next poll timeout.
            if (utils.consumeReload())
                handleConfigReload() catch |err| debug.err("Reload failed: {}", .{err});
        }

        // End-of-iteration fan-out
        inline for (plugins.list[0..plugins.count]) |p| {
            if (p.iteration_end) |f| _ = f();
        }
    }
}
