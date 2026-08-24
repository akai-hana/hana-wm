//! Refresh-rate detection via RandR.
//! Publishes the monitor refresh rate lock-free for bar render pacing.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const debug = @import("debug");

const utils = @import("utils");

/// Fallback used when RandR is unavailable or returns an invalid value.
const default_hz: f64 = 60.0;

/// Bar render pacing uses 1e9/rate; a value outside this band would
/// either spin the wake loop (huge rates) or starve the scroll (tiny rates),
/// so such readings are rejected rather than fed into the interval math.
const min_sane_hz: f64 = 10.0;
const max_sane_hz: f64 = 1000.0;

/// A single mode switch emits a burst of RandR notify events (screen + CRTC
/// + output change) that all describe the same configuration; the debounce
/// collapses the burst into one query.
const min_redetect_interval_ns: u64 = 100 * std.time.ns_per_ms;

/// RandR extension event base (`first_event`), 0 until detection has run.
/// Extension event types are server-assigned, so the event dispatcher can
/// only recognise them once the extension has been queried.
var randr_first_event: u8 = 0;

/// Detected monitor refresh rate in Hz. Written by the main thread on initial
/// detection and on RandR notify; read lock-free by render pacing.
var detected_rate_hz: std.atomic.Value(f64) = std.atomic.Value(f64).init(default_hz);

/// Latest detected monitor refresh rate in Hz; 60 until RandR provides a
/// sane reading, re-detected automatically on monitor reconfiguration.
pub fn detectedHz() f64 {
    return detected_rate_hz.load(.monotonic);
}

/// Only ever touched by the main thread (bar.init / title draws / config
/// reload), so a plain bool is race-free.
var detection_initialized: bool = false;

/// Monotonic timestamp of the most recent re-detection.
var last_redetect_ns: u64 = 0;

/// Perform one-time refresh-rate detection and subscribe to RandR notify
/// events so later monitor re-configurations re-detect. Idempotent; safe to
/// call from the main thread on every draw; the actual setup runs once and
/// subsequent calls return immediately.
pub fn ensureRefreshRateDetected(conn: core.Connection) void {
    if (detection_initialized) return;
    detection_initialized = true;
    const root = core.getState().root;
    if (setupRandr(conn, root)) detectRefreshRate(conn, root);
}

/// Lets the event dispatcher recognise RandR extension events (which sit
/// above the fixed core-event table) before the table lookup.
pub fn randrFirstEvent() u8 {
    return randr_first_event;
}

/// Called by the event loop on any RandR extension event (screen change, CRTC
/// change, output change). Re-detects the active refresh rate so bar pacing
/// cadence tracks monitor re-configuration. Main thread only.
pub fn handleRandrNotifyEvent(conn: core.Connection) void {
    const now = utils.monotonicNs();
    if (now -| last_redetect_ns < min_redetect_interval_ns) return;
    last_redetect_ns = now;
    detectRefreshRate(conn, core.getState().root);
}

fn setupRandr(conn: core.Connection, root: xcb.xcb_window_t) bool {
    const name = "RANDR";
    const ext_cookie = xcb.xcb_query_extension(conn, @intCast(name.len), name.ptr);
    const ext = xcb.xcb_query_extension_reply(conn, ext_cookie, null) orelse return false;
    defer std.c.free(ext);
    if (ext.*.present == 0 or ext.*.first_event == 0) return false;
    randr_first_event = ext.*.first_event;
    subscribeRandrNotify(conn, root);
    return true;
}

fn detectRefreshRate(conn: core.Connection, root: xcb.xcb_window_t) void {
    const res_cookie = xcb.xcb_randr_get_screen_resources_current(conn, root);
    const res = xcb.xcb_randr_get_screen_resources_current_reply(conn, res_cookie, null) orelse return;
    defer std.c.free(res);

    if (refreshRateFromOutputs(conn, root, res)) |rate| publishDetectedRate(rate);
}

/// Returns the refresh rate from the mode active on the screen's primary
/// output, falling back to other outputs if the primary has no active mode.
fn refreshRateFromOutputs(
    conn: core.Connection,
    root: xcb.xcb_window_t,
    res: *xcb.xcb_randr_get_screen_resources_current_reply_t,
) ?f64 {
    var primary: xcb.xcb_randr_output_t = 0;
    const primary_cookie = xcb.xcb_randr_get_output_primary(conn, root);
    if (xcb.xcb_randr_get_output_primary_reply(conn, primary_cookie, null)) |reply| {
        defer std.c.free(reply);
        primary = reply.*.output;
    }

    if (primary != 0) if (refreshRateFromOutput(conn, primary, res)) |rate| return rate;

    const outputs = xcb.xcb_randr_get_screen_resources_current_outputs(res);
    const output_count: usize = @intCast(xcb.xcb_randr_get_screen_resources_current_outputs_length(res));
    for (outputs[0..output_count]) |output| {
        if (output == primary) continue;
        if (refreshRateFromOutput(conn, output, res)) |rate| return rate;
    }
    return null;
}

/// Derives the refresh rate from the pixel clock: dot_clock / (htotal * vtotal).
fn findModeRate(modes: anytype, mode_id: anytype) ?f64 {
    for (modes) |mode| {
        if (mode.id != mode_id) continue;
        if (mode.htotal == 0 or mode.vtotal == 0) return null;
        return @as(f64, @floatFromInt(mode.dot_clock)) /
            (@as(f64, @floatFromInt(mode.htotal)) * @as(f64, @floatFromInt(mode.vtotal)));
    }
    return null;
}

/// Queries the output and its CRTC for the currently-active mode, then
/// resolves the mode's refresh rate from the mode table.
fn refreshRateFromOutput(
    conn: core.Connection,
    output: xcb.xcb_randr_output_t,
    res: *const xcb.xcb_randr_get_screen_resources_current_reply_t,
) ?f64 {
    const out_cookie = xcb.xcb_randr_get_output_info(conn, output, res.*.config_timestamp);
    const out = xcb.xcb_randr_get_output_info_reply(conn, out_cookie, null) orelse return null;
    defer std.c.free(out);
    const crtc = out.*.crtc;
    if (crtc == 0) return null;

    const crtc_cookie = xcb.xcb_randr_get_crtc_info(conn, crtc, res.*.config_timestamp);
    const crtc_info = xcb.xcb_randr_get_crtc_info_reply(conn, crtc_cookie, null) orelse return null;
    defer std.c.free(crtc_info);
    const mode_id = crtc_info.*.mode;
    if (mode_id == 0) return null;

    const modes = xcb.xcb_randr_get_screen_resources_current_modes(res);
    const mode_count: usize = @intCast(xcb.xcb_randr_get_screen_resources_current_modes_length(res));
    return findModeRate(modes[0..mode_count], mode_id);
}

fn publishDetectedRate(rate: f64) void {
    if (std.math.isFinite(rate) and rate >= min_sane_hz and rate <= max_sane_hz) {
        detected_rate_hz.store(rate, .monotonic);
        debug.info("Detected monitor refresh rate: {d:.2} Hz", .{rate});
    } else {
        debug.warn("Detected invalid refresh rate {d:.2} Hz, keeping fallback", .{rate});
    }
}

fn subscribeRandrNotify(conn: core.Connection, root: xcb.xcb_window_t) void {
    _ = xcb.xcb_randr_select_input(
        conn,
        root,
        @intCast(xcb.XCB_RANDR_NOTIFY_MASK_SCREEN_CHANGE |
            xcb.XCB_RANDR_NOTIFY_MASK_CRTC_CHANGE |
            xcb.XCB_RANDR_NOTIFY_MASK_OUTPUT_CHANGE),
    );
    _ = xcb.xcb_flush(conn);
}
