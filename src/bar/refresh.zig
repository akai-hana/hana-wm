//! Refresh-rate detection via RandR.
//! Publishes the monitor refresh rate lock-free for bar render pacing.
//! A bar feature by construction: the only consumer of the detected rate is
//! bar segment drawing (title/carousel pacing). Lives under src/bar so a
//! bar-less tree drops the whole RandR probe/subscribe machinery with the
//! directory; core's event loop reaches it only through the `Surfaces` seam.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const debug = @import("debug");

const utils = @import("utils");

/// Fallback used when RandR is unavailable or returns an invalid value.
const default_hz: f64 = 60.0;

/// Bar render pacing uses 1e9/rate; a value outside this band would
/// either spin the wake loop (huge rates) or starve the refresh cadence
/// (tiny rates), so such readings are rejected rather than fed into the
/// interval math.
const min_sane_hz: f64 = 10.0;
const max_sane_hz: f64 = 1000.0;

/// A single mode switch emits a burst of RandR notify events (screen + CRTC
/// + output change) that all describe the same configuration; the debounce
/// collapses the burst into one query.
const min_redetect_interval_ns: u64 = 100 * std.time.ns_per_ms;

/// Bounds for the pipeline scratch arrays. Real setups have a handful of
/// outputs/crtcs; these caps are far above anything a single screen can
/// expose while keeping the detection fully stack-allocated (no allocator
/// dependency in the boot path).
const max_outputs = 64;
const max_cached_modes = 256;

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

/// Deferred re-detection flag, set by handleRandrNotifyEvent and consumed by
/// runPendingRedetect. The actual detection makes several synchronous XCB
/// round-trips, so it is never run from inside event dispatch.
var redetect_pending: bool = false;

/// Called by the event loop on any RandR extension event (screen change, CRTC
/// change, output change).
///
/// Fast path: an RRNotify event carrying a CRTC change puts the newly-active
/// mode id directly in the payload. When that mode is present in the cached
/// mode table (populated on the last detection), the rate is resolved with
/// zero additional XCB requests and published immediately.
///
/// Fallback: any event without an in-cache mode (screen/output changes, or a
/// mode not yet in the table) is rate-limited and flags a deferred full
/// re-detection, which runs at a controlled point in the loop
/// (runPendingRedetect) and refreshes the cached mode table. Main thread only.
pub fn handleRandrNotifyEvent(event: *anyopaque) void {
    if (rateFromNotifyEvent(event)) |rate| {
        // A burst of RandR notify events describes one configuration. Once the
        // mode is resolved from the payload, drop any full re-detection that a
        // sibling event (e.g. screen change) in the same burst may have queued;
        // the cached table already holds the authoritative rate for this mode.
        redetect_pending = false;
        publishDetectedRate(rate);
        return;
    }

    const now = utils.monotonicNs();
    if (now -| last_redetect_ns < min_redetect_interval_ns) return;
    last_redetect_ns = now;
    redetect_pending = true;
}

/// Runs the deferred re-detection, if one is pending. Called once per event
/// loop batch from run(), after all events in the batch have been dispatched,
/// so the synchronous RandR round-trips can't stall the handling of the other
/// events (e.g. MapRequest) the same batch carried. Main thread only.
pub fn runPendingRedetect(conn: core.Connection) void {
    if (!redetect_pending) return;
    redetect_pending = false;
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

// Cached mode table
//
// The screen-resources reply carries the full mode table (id -> refresh rate).
// It is cached at every detection so the CRTC-change event path can resolve a
// mode id from an event payload with zero XCB requests. Main-thread only.

const CachedMode = struct {
    id: xcb.xcb_randr_mode_t,
    hz: f64,
};

var cached_modes: [max_cached_modes]CachedMode = undefined;
var cached_mode_count: usize = 0;

/// Precomputes the refresh rate for every mode in the resources reply and
/// stores it in the cache (capped at max_cached_modes).
fn cacheModes(modes: []xcb.xcb_randr_mode_info_t) void {
    if (modes.len > max_cached_modes) {
        // The CRTC-change fast path can only resolve mode ids held in the
        // cache, and RandR has no targeted per-mode rate request to fetch one
        // on demand. Overflowed modes therefore always fall back to a full
        // re-detect when they become active; surface it rather than stall it.
        debug.warn(
            "refresh: {} modes exceed the {}-mode cache; extra modes fall back to full re-detection",
            .{ modes.len, max_cached_modes },
        );
    }
    cached_mode_count = @min(modes.len, max_cached_modes);
    for (modes[0..cached_mode_count], 0..) |mode, i| {
        cached_modes[i] = .{
            .id = mode.id,
            .hz = if (mode.htotal == 0 or mode.vtotal == 0)
                0.0
            else
                @as(f64, @floatFromInt(mode.dot_clock)) /
                    (@as(f64, @floatFromInt(mode.htotal)) * @as(f64, @floatFromInt(mode.vtotal))),
        };
    }
}

/// Looks up the refresh rate for a mode id in the cached table. Returns null
/// when the id is absent or the mode yields no valid rate.
fn rateForModeId(mode_id: xcb.xcb_randr_mode_t) ?f64 {
    for (cached_modes[0..cached_mode_count]) |m|
        if (m.id == mode_id and m.hz > 0.0) return m.hz;
    return null;
}

/// Extracts the refresh rate from a RandR event payload when possible:
/// an RRNotify event (extension base + 1) whose CRTC-change member carries the
/// newly-active mode id, resolved from the cached mode table. Returns null for
/// every other event (screen change, output change, unknown subCode, or a mode
/// absent from the cache), signalling the caller to fall back to a full detect.
fn rateFromNotifyEvent(event: *anyopaque) ?f64 {
    // Only the RRNotify event (base + 1) carries a subCode and notify-data
    // union. The screen-change event (base) has a rotation byte in the same
    // offset as subCode, so trust it only when response_type matches base + 1.
    if (randr_first_event == 0) return null;
    const notify = utils.eventCast(*xcb.xcb_randr_notify_event_t, event);
    // Widen before adding 1: an extension base of 255 would wrap the u8 add
    // to 0 and silently disable re-detection for that server.
    if (notify.*.response_type != @as(u16, randr_first_event) + 1) return null;
    if (notify.*.subCode != xcb.XCB_RANDR_NOTIFY_CRTC_CHANGE) return null;
    const mode_id = notify.*.u.cc.mode;
    if (mode_id == 0) return null;
    return rateForModeId(mode_id);
}

// Pipelined refresh detection
//
// The old path fired one request and immediately drained it with _reply,
// blocking per dependant: screen resources, then output primary, then per
// output (output info -> crtc info) = 1 + 2*N blocking waits. The pipelined
// path fires every independent cookie first, then collects the replies in
// order (poll-preferring via the XCB reply calls), collapsing the N waits into
// three phases: (1) resources + primary, (2) all output infos, (3) all crtc
// infos.

fn detectRefreshRate(conn: core.Connection, root: xcb.xcb_window_t) void {
    // Phase 1: fire both independent requests, then drain them in order.
    const res_cookie = xcb.xcb_randr_get_screen_resources_current(conn, root);
    const primary_cookie = xcb.xcb_randr_get_output_primary(conn, root);

    const res = xcb.xcb_randr_get_screen_resources_current_reply(conn, res_cookie, null) orelse {
        // The primary-output reply is already in flight; if we return now
        // it would sit unconsumed and desync the next reply read on this
        // connection. Discard it (no reply allocation, no blocking wait).
        xcb.xcb_discard_reply(conn, primary_cookie.sequence);
        return;
    };
    defer std.c.free(res);

    var primary: xcb.xcb_randr_output_t = 0;
    if (xcb.xcb_randr_get_output_primary_reply(conn, primary_cookie, null)) |reply| {
        defer std.c.free(reply);
        primary = reply.*.output;
    }

    // Cache the mode table while it is in hand; the event path reuses it to
    // resolve CRTC-change mode ids with zero requests.
    const modes = xcb.xcb_randr_get_screen_resources_current_modes(res);
    const mode_count: usize = @intCast(
        xcb.xcb_randr_get_screen_resources_current_modes_length(res),
    );
    cacheModes(modes[0..mode_count]);

    if (pipelinedRefreshRateFromOutputs(conn, res, primary)) |rate| publishDetectedRate(rate);
}

/// Returns the refresh rate of the mode active on the screen's primary output,
/// falling back to other outputs when the primary has no active mode. All
/// output-info requests are fired before any reply is collected, and all
/// crtc-info requests are fired before any reply is collected, so the whole
/// probe takes ~3 blocking waits regardless of output count (vs 1 + 2*N before).
fn pipelinedRefreshRateFromOutputs(
    conn: core.Connection,
    res: *xcb.xcb_randr_get_screen_resources_current_reply_t,
    primary: xcb.xcb_randr_output_t,
) ?f64 {
    const outputs = xcb.xcb_randr_get_screen_resources_current_outputs(res);
    const output_count: i32 = xcb.xcb_randr_get_screen_resources_current_outputs_length(res);
    if (output_count <= 0) return null;
    const n_out: usize = @intCast(output_count);

    // Build a priority-ordered candidate list (primary first), capped.
    var order: [max_outputs]xcb.xcb_randr_output_t = undefined;
    var n_order: usize = 0;
    if (primary != 0) {
        order[0] = primary;
        n_order = 1;
    }
    for (outputs[0..@min(n_out, max_outputs)]) |out| {
        if (out == primary) continue;
        if (n_order >= max_outputs) break;
        order[n_order] = out;
        n_order += 1;
    }
    if (n_order == 0) return null;

    // Phase 2: fire an output-info request for every candidate, then collect.
    var out_cookies: [max_outputs]xcb.xcb_randr_get_output_info_cookie_t = undefined;
    var out_info_ptrs: [max_outputs]?*xcb.xcb_randr_get_output_info_reply_t = undefined;
    @memset(out_info_ptrs[0..n_order], null);
    const config_ts = res.*.config_timestamp;
    for (order[0..n_order], 0..) |out, i|
        out_cookies[i] = xcb.xcb_randr_get_output_info(conn, out, config_ts);
    for (order[0..n_order], 0..) |_, i| {
        const info = xcb.xcb_randr_get_output_info_reply(conn, out_cookies[i], null) orelse continue;
        out_info_ptrs[i] = info;
    }
    defer for (order[0..n_order], 0..) |_, i| {
        if (out_info_ptrs[i]) |info| std.c.free(info);
    };

    // Phase 3: fire a crtc-info request for every output that has a CRTC.
    var crtc_cookies: [max_outputs]xcb.xcb_randr_get_crtc_info_cookie_t = undefined;
    for (order[0..n_order], 0..) |_, i| {
        const info = out_info_ptrs[i] orelse continue;
        const crtc = info.crtc;
        if (crtc == 0) continue;
        crtc_cookies[i] = xcb.xcb_randr_get_crtc_info(conn, crtc, config_ts);
    }

    // Collect the crtc replies in priority order and resolve the active mode.
    for (order[0..n_order], 0..) |_, i| {
        const info = out_info_ptrs[i] orelse continue;
        if (info.crtc == 0) continue;
        const crtc_info = xcb.xcb_randr_get_crtc_info_reply(conn, crtc_cookies[i], null) orelse
            continue;
        const mode_id = crtc_info.*.mode;
        std.c.free(crtc_info);
        if (mode_id == 0) continue;
        if (rateForModeId(mode_id)) |rate| return rate;
    }
    return null;
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
