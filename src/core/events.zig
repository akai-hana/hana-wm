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

const tiling = @import("tiling");
const bar = @import("bar");
const prompt = @import("prompt");
const clock = @import("clock");
const fullscreen = @import("fullscreen");
const scale = @import("scale");

// Indices into the poll fd array.
const FD_XCB = 0;
const FD_SIGNAL = 1;

/// Maximum events dispatched per XCB batch before returning to poll, so the
/// signal pipe and timer paths get fair scheduling against a chatty client.
const MAX_EVENTS_PER_BATCH: usize = 128;

// Aliases to canonical definitions in constants.zig.
const EVENT_DISPATCH_TABLE = constants.Limits.EVENT_DISPATCH_TABLE;
const MAX_KEYBIND_COOKIES = constants.Limits.MAX_KEYBIND_COOKIES;
const LOCK_MODIFIERS = constants.LOCK_MODIFIERS;

// Self-pipe for portable signal delivery.
// Signal handlers write to [1]; the event loop polls [0].
var signal_pipe: [2]std.posix.fd_t = .{ -1, -1 };

// Dispatch table

const EventHandler = *const fn (event: *anyopaque) void;

inline fn asHandler(comptime f: anytype) EventHandler {
    return @ptrCast(&f);
}

/// Fans out PropertyNotify to both bar (title) and window (WM_PROTOCOLS cache).
fn handlePropertyNotify(event: *anyopaque) void {
    const e: *xcb.xcb_property_notify_event_t = @ptrCast(@alignCast(event));
    bar.handlePropertyNotify(e);
    window.handlePropertyNotify(e);
}

/// Routes ConfigureNotify to the fullscreen deferred-bar-hide/show logic.
fn handleConfigureNotify(event: *anyopaque) void {
    const e: *xcb.xcb_configure_notify_event_t = @ptrCast(@alignCast(event));
    fullscreen.notifyConfigureIfPending(e.window, e.width, e.height);
}

/// Notifies fullscreen of the destroyed window before delegating to window.zig.
/// This clears any pending deferred bar-show for a window that exits fullscreen
/// and is then destroyed before it can send a ConfigureNotify.
fn handleDestroyNotify(event: *anyopaque) void {
    const e: *xcb.xcb_destroy_notify_event_t = @ptrCast(@alignCast(event));
    fullscreen.onWindowGone(e.window);
    window.handleDestroyNotify(e);
}

/// O(1) dispatch via a comptime-built table indexed by XCB event type (low 7 bits).
const dispatch_table = blk: {
    var table = [_]?EventHandler{null} ** EVENT_DISPATCH_TABLE;

    table[xcb.XCB_ENTER_NOTIFY] = asHandler(window.handleEnterNotify);
    table[xcb.XCB_LEAVE_NOTIFY] = asHandler(window.handleLeaveNotify);

    table[xcb.XCB_MAP_REQUEST] = asHandler(window.handleMapRequest);
    table[xcb.XCB_CONFIGURE_REQUEST] = asHandler(window.handleConfigureRequest);
    table[xcb.XCB_UNMAP_NOTIFY] = asHandler(window.handleUnmapNotify);
    table[xcb.XCB_DESTROY_NOTIFY] = asHandler(handleDestroyNotify);
    table[xcb.XCB_CLIENT_MESSAGE] = asHandler(window.handleClientMessage);

    table[xcb.XCB_KEY_PRESS] = asHandler(input.handleKeyPress);
    table[xcb.XCB_MAPPING_NOTIFY] = asHandler(input.handleMappingNotify);
    table[xcb.XCB_BUTTON_PRESS] = asHandler(input.handleButtonPress);
    table[xcb.XCB_BUTTON_RELEASE] = asHandler(input.handleButtonRelease);
    table[xcb.XCB_MOTION_NOTIFY] = asHandler(input.handleMotionNotify);
    table[xcb.XCB_FOCUS_IN] = asHandler(focus.handleFocusIn);
    table[xcb.XCB_PROPERTY_NOTIFY] = asHandler(handlePropertyNotify);

    table[xcb.XCB_EXPOSE] = asHandler(bar.handleExpose);

    table[xcb.XCB_CONFIGURE_NOTIFY] = asHandler(handleConfigureNotify);

    break :blk table;
};

fn dispatch(event_type: u8, event: *anyopaque) void {
    // Type 0 is an X error pseudo-event produced for a failed *unchecked*
    // request. Nothing else in this codebase subscribes to type-0, so without
    // this branch such errors would be silently dropped — making real-world
    // X11 failures (bad grabs, stale window ids, wrong atoms) undiagnosable.
    if (event_type == 0) {
        const e: *xcb.xcb_generic_error_t = @ptrCast(@alignCast(event));
        debug.warn("Unchecked XCB request failed: code={} major={} minor={} resource={x}", .{
            e.error_code, e.major_code, e.minor_code, e.resource_id,
        });
        return;
    }
    const idx = event_type & 0x7F; // strip XCB synthetic-event bit

    // RandR extension events (extension base and base+1): screen, CRTC, and
    // output change notifications. The carousel's refresh-rate cadence must
    // track monitor re-configuration (xrandr mode switch, hotplug), so any of
    // them triggers a re-detection. Extension events sit above the fixed
    // dispatch table and would otherwise be dropped by the bounds guard below.
    const randr_first = scale.randrFirstEvent();
    if (randr_first != 0 and idx >= randr_first and idx <= randr_first + 1) {
        scale.handleRandrNotifyEvent(core.getState().conn);
        return;
    }

    // Guard the fixed-size table: extension events live above XCB_GE_GENERIC
    // and would index out of bounds. hana only selects core events today, but
    // the moment anyone subscribes to an extension this would become a
    // memory-safety bug — cheap insurance.
    if (idx >= dispatch_table.len) return;
    if (dispatch_table[idx]) |handler| handler(event);
}

// Signal handling

/// Async-signal-safe handler: writes the signal number as a byte to the pipe.
fn signalHandler(signo: std.posix.SIG) callconv(.c) void {
    const byte: u8 = @intCast(@intFromEnum(signo));
    _ = std.os.linux.write(signal_pipe[1], &[_]u8{byte}, 1);
}

/// Creates the signal self-pipe and installs handlers for SIGHUP/SIGTERM/SIGINT/SIGCHLD.
pub fn setupSignalPipe() !void {
    signal_pipe = try utils.makePipe();
    utils.setSignalWriteFd(signal_pipe[1]);

    const sa: std.posix.Sigaction = .{
        .handler = .{ .handler = signalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };

    // SIGCHLD is reaped in dispatchSignal; the rest control the event loop.
    inline for (.{ std.posix.SIG.HUP, std.posix.SIG.TERM, std.posix.SIG.INT, std.posix.SIG.CHLD }) |sig|
        std.posix.sigaction(sig, &sa, null);
}

/// Closes both ends of the signal pipe.
pub fn deinitSignalPipe() void {
    utils.setSignalWriteFd(-1);
    for (&signal_pipe) |*fd| {
        if (fd.* == -1) continue;
        _ = std.os.linux.close(fd.*);
        fd.* = -1;
    }
}

/// Dispatches a single signal byte to the appropriate handler.
inline fn dispatchSignal(byte: u8) void {
    switch (@as(std.posix.SIG, @enumFromInt(byte))) {
        .HUP => utils.reload(),
        .TERM, .INT => utils.quit(),
        // SIGCHLD: an intermediate double-fork child has exited.
        // Reap it with WNOHANG, then immediately drain the spawn pipes so
        // registerSpawn fires without waiting for the next XCB event batch.
        .CHLD => {
            input.reapPendingChildren();
            input.drainPendingSpawns();
        },
        else => {},
    }
}

const SIGNAL_DRAIN_BUF = 16; // drain a burst in one syscall rather than one per byte

/// Drains the non-blocking signal pipe and dispatches each signal.
///
/// std.os.linux.read returns usize (the raw syscall result).  On error the
/// kernel returns a negative value, which wraps to a huge unsigned number;
/// an unsigned comparison against that value never reads as negative, so it
/// would escape unchecked into @intCast and the slice bounds check.  Bitcast
/// to isize first and treat any non-positive result (error or EOF) as a stop
/// condition.
fn handleSignalPipe(fd: std.posix.fd_t) void {
    var buf: [SIGNAL_DRAIN_BUF]u8 = undefined;
    while (true) {
        const rc: isize = @bitCast(std.os.linux.read(fd, &buf, buf.len));
        if (rc <= 0) break; // 0 = EOF on write-end close, negative = error/EAGAIN
        const n: usize = @intCast(rc);
        for (buf[0..n]) |byte| dispatchSignal(byte);
    }
}

// Keybindings

const CookieEntry = struct { cookie: xcb.xcb_void_cookie_t, keycode: u8 };

/// Fills `cookies` with one grab request per (keybinding × lock modifier) pair.
/// Returns the number of entries written.
fn fillGrabCookies(cookies: []CookieEntry) usize {
    var n: usize = 0;
    const cs = core.getState();
    for (cs.config.keybindings.items) |kb| {
        const keycode = kb.keycode orelse continue;

        // Check once per keybinding that the full lock-modifier set fits.
        // Avoids a per-lock branch and prevents partial grabs if the buffer is nearly full.
        if (n + LOCK_MODIFIERS.len > cookies.len) {
            debug.warn("Too many keybindings. Increase MAX_KEYBIND_COOKIES (currently {})", .{MAX_KEYBIND_COOKIES});
            break;
        }

        for (LOCK_MODIFIERS) |lock| {
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

    var cookies: [MAX_KEYBIND_COOKIES]CookieEntry = undefined;
    const n = fillGrabCookies(&cookies);

    const failed = checkGrabCookies(cookies[0..n]);
    if (failed > 0) debug.warn("{} keybinding(s) failed to grab", .{failed});

    _ = xcb.xcb_flush(cs.conn);
}

// Config reload

/// Loads and validates a new config, then applies it atomically.
/// On failure, the old config remains active.
///
/// Ordering matters for every step:
///   1. Keybind resolution and DPI scaling operate directly on `new_config`
///      and must run before the swap.
///   2. The swap (old -> new) happens BEFORE the subsystem reloads below, so
///      window.reloadBorders()/tiling.reloadConfig()/bar.reload() — which all
///      read core.getState().config — rebuild from the NEW config, not the
///      stale one. (The old ordering silently kept bar/tiling/border settings
///      from the previous config, then old_config.deinit() freed the bar
///      string slices the new bar had shallow-copied: a use-after-free on the
///      next bar draw.)
///   3. grabKeybindings() must run after the swap: fillGrabCookies() reads
///      core.getState().config.keybindings, so grabbing before the swap would
///      re-grab the OLD keycodes.
///   4. `committed` flips the errdefer: before the swap a failure must free the
///      unused new_config; after the swap new_config is the live config, so a
///      failure must instead keep it and free the displaced old_config.
///      (Today every post-swap call returns void, so this is latent-but-safe —
///      bar.reload() swallows its own errors and keeps the old bar, which
///      applyReload re-points at the new config before that.)
///   5. config.applyCarouselSettings() runs only after the swap so a rejected
///      reload never leaks carousel settings into effect (they are staged on
///      the config struct at parse time, not written to globals).
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
    tiling.reloadConfig();
    bar.reload();

    old_config.deinit(cs.alloc);

    grabKeybindings();

    // Rebuild after the swap so borrowed key slices point into the new config's memory.
    window.buildRulesMap();

    config.applyCarouselSettings(&new_config);

    debug.info("Reload complete", .{});
}

// Event loop

/// Ticks the cursor blink and drains the clock thread's redraw request on
/// poll timeout, then flushes to the compositor.
fn handleTimerEvents(cursor_is_blinking: bool) void {
    // poll() times out for cursor blink and/or the clock's next whole-second
    // boundary. The clock thread formats the time string and sets a dirty
    // flag; bar.updateClock() (below) runs the Pango layout for the clock
    // segment here on the main thread.
    if (cursor_is_blinking) {
        prompt.blinkTick();
        bar.submitDraw();
        _ = xcb.xcb_flush(core.getState().conn);
    }
    _ = bar.updateClock();
}

/// Drains pending XCB events for this batch, then runs post-batch housekeeping.
fn handleXcbEvents() void {
    const conn = core.getState().conn;

    // Cap the number of events dispatched per batch so a chatty client
    // flooding PropertyNotify/ConfigureNotify can't starve the signal pipe and
    // timer paths (clock, cursor blink) indefinitely. Unread events stay in the
    // socket buffer and the fd stays readable, so they're handled on the next
    // poll round.
    var handled: usize = 0;
    while (handled < MAX_EVENTS_PER_BATCH) : (handled += 1) {
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

    tiling.retileIfDirty();
    focus.drainPendingConfirm();
    focus.drainPointerSync();
    // Must run after the event-draining loop above: any EnterNotify a tiling
    // reflow generated has to have already been dispatched (and filtered,
    // since suppression is still active) before this lifts suppression.
    // See beginTilingOpSettle's doc comment in focus.zig.
    focus.drainTilingOpSettle();
    window.updateWorkspaceBordersIfNeeded();
    bar.updateIfDirty() catch |err| debug.err("Failed to update bar: {}", .{err});
    // Drain the clock thread's redraw request here too, not only on poll
    // timeout: a busy main loop that never lets the timeout expire (constant
    // XCB traffic) would otherwise starve the clock repaint.
    _ = bar.updateClock();

    _ = xcb.xcb_flush(conn);
}

pub fn run() !void {
    const x_fd: std.posix.fd_t = xcb.xcb_get_file_descriptor(core.getState().conn);
    const signal_fd: std.posix.fd_t = signal_pipe[0];

    var fds = [_]std.posix.pollfd{
        .{ .fd = x_fd, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = signal_fd, .events = std.posix.POLL.IN, .revents = 0 },
    };

    while (utils.running.load(.acquire)) {
        // Wake for the earlier of the cursor-blink deadline and the clock's
        // next whole-second tick (plus grace). The clock deadline keeps the
        // loop ticking even when nothing else is happening, and also provides
        // the short-retry behaviour inside clock.nextTickWaitMs when the clock
        // thread is late publishing a second.
        const blink_ms = prompt.blinkPollTimeoutMs();
        const cursor_is_blinking = blink_ms >= 0;
        const clock_ms: i32 = @intCast(clock.nextTickWaitMs());
        const poll_ms: i32 = if (blink_ms < 0) clock_ms else @min(blink_ms, clock_ms);
        const poll_rc = std.os.linux.poll(&fds, fds.len, poll_ms);
        const ready: usize = switch (std.posix.errno(poll_rc)) {
            .SUCCESS => @intCast(poll_rc),
            .INTR => continue,
            else => |err| {
                debug.err("poll error: {s}", .{@errorName(std.posix.unexpectedErrno(err))});
                break;
            },
        };

        if (ready == 0) {
            handleTimerEvents(cursor_is_blinking);
            continue;
        }

        if ((fds[FD_XCB].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP)) != 0) {
            debug.err("X11 connection error, shutting down", .{});
            break;
        }

        if ((fds[FD_XCB].revents & std.posix.POLL.IN) != 0) handleXcbEvents();

        if ((fds[FD_SIGNAL].revents & std.posix.POLL.IN) != 0)
            handleSignalPipe(signal_fd);

        // The reload flag is also set directly by the reload_config keybinding
        // (which writes a wake byte to the pipe, but the byte can be dropped if
        // the pipe is full). Consume it every iteration so that path can never
        // be lost — a flag-only request is picked up on the next poll timeout.
        if (utils.consumeReload())
            handleConfigReload() catch |err| debug.err("Reload failed: {}", .{err});
    }
}
