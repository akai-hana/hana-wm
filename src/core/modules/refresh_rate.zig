//! Refresh-rate detection via RandR
//! Detects the monitor's refresh rate and publishes it lock-free for the
//! carousel thread. Re-detects on RandR notify events (mode switches,
//! hotplug, rate changes).

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const debug = @import("debug");

const utils = @import("utils");

/// Fallback refresh rate used when RandR is unavailable or returns an invalid value.
const default_hz: f64 = 60.0;

/// Sanity band for a detected refresh rate. The carousel's wake interval is
/// 1e9/rate; a value outside this band would either spin the wake loop (huge
/// rates) or starve the scroll (tiny rates), so such readings are rejected
/// rather than fed straight into the interval math.
const MIN_SANE_HZ: f64 = 10.0;
const MAX_SANE_HZ: f64 = 1000.0;

/// Minimum gap between re-detections. A single mode switch emits a burst of
/// RandR notify events (screen + CRTC + output change) that all describe the
/// same configuration; the debounce collapses the burst into one query.
const min_redetect_interval_ns: u64 = 100 * std.time.ns_per_ms;

/// RandR extension event base (`first_event`), 0 until detection has run.
/// Extension event types are server-assigned, so the event dispatcher can
/// only recognise them once the extension has been queried.
var randr_first_event: u8 = 0;

/// Detected monitor refresh rate in Hz. Written by the main thread (initial
/// detection and on RandR notify); read by the carousel thread from
/// `wakeIntervalNs`, hence atomic.
var detected_rate_hz: std.atomic.Value(f64) = std.atomic.Value(f64).init(default_hz);

/// True once the one-time initial detection has run. Only ever touched by the
/// main thread (bar.init / title draws / config reload), so a plain bool is
/// race-free.
var detection_initialized: bool = false;

/// Monotonic timestamp of the most recent re-detection. Debounces the burst
/// of RandR notify events a single mode switch generates (screen + CRTC +
/// output change) down to one query instead of one query per event.
var last_redetect_ns: u64 = 0;

/// Perform one-time refresh-rate detection and subscribe to RandR notify
/// events so later monitor re-configurations re-detect. Idempotent; safe to
/// call from the main thread on every draw; the actual setup runs once and
/// subsequent calls return immediately.
pub fn ensureRefreshRateDetected(conn: *xcb.xcb_connection_t) void {
    if (detection_initialized) return;
    detection_initialized = true;
    const root = core.getState().root;
    if (setupRandr(conn, root)) detectRefreshRate(conn, root);
}

/// RandR extension event base, or 0 when detection has not yet run. Lets the
/// event dispatcher recognise RandR extension events (which sit above the
/// fixed core-event table) before the table lookup.
pub fn randrFirstEvent() u8 {
    return randr_first_event;
}

/// Returns the detected refresh rate in Hz (60 Hz fallback before detection
/// runs or when RandR is unavailable).
pub fn getDetectedRateHz() f64 {
    return detected_rate_hz.load(.monotonic);
}

/// Called by the event loop on any RandR extension event (screen change, CRTC
/// change, output change, the only masks this module subscribes to).
/// Re-detects the active refresh rate so the carousel cadence tracks monitor
/// re-configuration. Main thread only.
pub fn handleRandrNotifyEvent(conn: *xcb.xcb_connection_t) void {
    const now = utils.monotonicNs();
    if (now -| last_redetect_ns < min_redetect_interval_ns) return;
    last_redetect_ns = now;
    detectRefreshRate(conn, core.getState().root);
}

/// Resolves the RandR extension's server-assigned event base and enables the
/// notify events that drive re-detection. Returns false when RandR is absent
/// or unusable.
fn setupRandr(conn: *xcb.xcb_connection_t, root: xcb.xcb_window_t) bool {
    const name = "RANDR";
    const ext_cookie = xcb.xcb_query_extension(conn, @intCast(name.len), name.ptr);
    const ext = xcb.xcb_query_extension_reply(conn, ext_cookie, null) orelse return false;
    defer std.c.free(ext);
    if (ext.*.present == 0 or ext.*.first_event == 0) return false;
    randr_first_event = ext.*.first_event;
    subscribeRandrNotify(conn, root);
    return true;
}

/// Queries the currently-active RandR mode and publishes its derived refresh
/// rate. Falls back to `default_hz` on any failure.
fn detectRefreshRate(conn: *xcb.xcb_connection_t, root: xcb.xcb_window_t) void {
    const res_cookie = xcb.xcb_randr_get_screen_resources_current(conn, root);
    const res = xcb.xcb_randr_get_screen_resources_current_reply(conn, res_cookie, null) orelse return;
    defer std.c.free(res);

    if (refreshRateFromOutputs(conn, root, res)) |rate| publishDetectedRate(rate);
}

/// Returns the refresh rate of the mode active on the screen's primary output,
/// or null when nothing usable is found.
fn refreshRateFromOutputs(
    conn: *xcb.xcb_connection_t,
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

/// Matches `mode_id` against a RandR mode list and returns its refresh rate
/// derived from the pixel clock.
fn findModeRate(modes: anytype, mode_id: anytype) ?f64 {
    for (modes) |mode| {
        if (mode.id != mode_id) continue;
        if (mode.htotal == 0 or mode.vtotal == 0) return null;
        return @as(f64, @floatFromInt(mode.dot_clock)) /
            (@as(f64, @floatFromInt(mode.htotal)) * @as(f64, @floatFromInt(mode.vtotal)));
    }
    return null;
}

/// Returns the refresh rate of the mode currently active on `output`, or null
/// when the output is disconnected or inactive.
fn refreshRateFromOutput(
    conn: *xcb.xcb_connection_t,
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

/// Publishes `rate` to the atomic read by the carousel thread, rejecting
/// non-finite or out-of-band readings.
fn publishDetectedRate(rate: f64) void {
    if (std.math.isFinite(rate) and rate >= MIN_SANE_HZ and rate <= MAX_SANE_HZ) {
        detected_rate_hz.store(rate, .monotonic);
        debug.info("Detected monitor refresh rate: {d:.2} Hz", .{rate});
    } else {
        debug.warn("Detected invalid refresh rate {d:.2} Hz, keeping fallback", .{rate});
    }
}

/// Enables RandR notify events on the root window.
fn subscribeRandrNotify(conn: *xcb.xcb_connection_t, root: xcb.xcb_window_t) void {
    _ = xcb.xcb_randr_select_input(
        conn,
        root,
        @intCast(xcb.XCB_RANDR_NOTIFY_MASK_SCREEN_CHANGE |
            xcb.XCB_RANDR_NOTIFY_MASK_CRTC_CHANGE |
            xcb.XCB_RANDR_NOTIFY_MASK_OUTPUT_CHANGE),
    );
    _ = xcb.xcb_flush(conn);
}
