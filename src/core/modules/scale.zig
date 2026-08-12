//! DPI detection and scaling utilities
//! Detects display DPI and scales bar dimensions for consistent appearance across resolutions.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const constants = @import("constants");
const debug = @import("debug");

const parser = @import("parser");
const utils = @import("utils");

const BASELINE_DPI = constants.BASELINE_DPI;

// Font size percentages are relative to 1080 p height, not the screen's own
// resolution, so font sizing degrades more gracefully on smaller screens.
const FONT_BASELINE_HEIGHT: f32 = 1080.0;

/// Minimum bar height in pixels. Exposed so callers can validate config values
/// before passing them to scaleBarHeight.
pub const BAR_MIN_HEIGHT_PX: u16 = 20;

/// Reasonable-DPI band applied to both the geometry-derived and Xft.dpi paths.
/// Values outside this range (or non-finite) are rejected as misconfiguration
/// rather than being fed straight into Pango, where 0/negative/NaN DPI would
/// produce divide-by-zero or garbage font metrics.
const MIN_REASONABLE_DPI: f32 = 50.0;
const MAX_REASONABLE_DPI: f32 = 300.0;

/// Maximum long-words to request for the RESOURCE_MANAGER property (16 KB).
const RESOURCE_MANAGER_MAX_LEN: u32 = 4096;

/// Reads the Xft.dpi value from the X RESOURCE_MANAGER property, if present.
/// Returns null when the property is absent, empty, or does not contain an Xft.dpi entry.
fn readXftDpi(conn: *xcb.xcb_connection_t, screen: *xcb.xcb_screen_t) ?f32 {
    // Resolve the atom from the shared cache; a property request with atom 0
    // just comes back empty, so a cache miss reads as "no Xft.dpi".
    const atom = utils.getAtomCached("RESOURCE_MANAGER") catch 0;

    const prop_cookie = xcb.xcb_get_property(conn, 0, screen.*.root, atom, xcb.XCB_ATOM_STRING, 0, RESOURCE_MANAGER_MAX_LEN);
    const prop_reply = xcb.xcb_get_property_reply(conn, prop_cookie, null) orelse return null;
    defer std.c.free(prop_reply);

    if (prop_reply.*.format != 8 or prop_reply.*.type != xcb.XCB_ATOM_STRING) return null;

    const value_len = xcb.xcb_get_property_value_length(prop_reply);
    if (value_len == 0) return null;

    const value_ptr = xcb.xcb_get_property_value(prop_reply);
    const resource_str = @as([*]const u8, @ptrCast(value_ptr))[0..@intCast(value_len)];

    // Format: "Xft.dpi:\t96" or "Xft.dpi: 96".
    // Slice off the prefix and trim whitespace — avoids the split-on-delimiter
    // trap where ":\t" would yield an empty token before the value.
    const prefix = "Xft.dpi:";
    var lines = std.mem.splitScalar(u8, resource_str, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, prefix)) {
            const rest = std.mem.trim(u8, trimmed[prefix.len..], " \t");
            const dpi = std.fmt.parseFloat(f32, rest) catch continue;
            return dpi;
        }
    }
    return null;
}

/// Computes DPI from the screen's physical dimensions reported by X.
/// Returns BASELINE_DPI if the screen reports 0mm dimensions (e.g. virtual displays).
fn calcDpiFromGeometry(screen: *xcb.xcb_screen_t) f32 {
    const width_px: f32 = @floatFromInt(screen.width_in_pixels);
    const height_px: f32 = @floatFromInt(screen.height_in_pixels);
    const width_mm: f32 = @floatFromInt(screen.width_in_millimeters);
    const height_mm: f32 = @floatFromInt(screen.height_in_millimeters);
    if (width_mm == 0 or height_mm == 0) {
        debug.warn("Display reports 0mm dimensions, using baseline DPI", .{});
        return BASELINE_DPI;
    }
    const dpi_x = (width_px / width_mm) * 25.4;
    const dpi_y = (height_px / height_mm) * 25.4;
    const avg_dpi = (dpi_x + dpi_y) / 2.0;
    debug.info("Calculated DPI: X={d:.1}, Y={d:.1}, Average={d:.1}", .{ dpi_x, dpi_y, avg_dpi });
    return avg_dpi;
}

/// Detect DPI: Xft.dpi from X resources -> geometry calculation -> BASELINE_DPI (96).
/// Called once at startup; core.dpi_info holds the result for the process lifetime.
pub fn detectDpi(conn: *xcb.xcb_connection_t, screen: *xcb.xcb_screen_t) f32 {
    if (readXftDpi(conn, screen)) |xft_dpi| {
        // Same reasonableness band as the geometry path: a broken Xft.dpi value
        // (0, negative, NaN, inf, absurd) flows straight into Pango's resolution
        // and would crash or corrupt bar rendering. Reject it and fall through.
        if (isReasonableDpi(xft_dpi)) {
            debug.info("Using DPI from X resources (Xft.dpi): {d:.1}", .{xft_dpi});
            return xft_dpi;
        }
        debug.warn("Ignoring unreasonable Xft.dpi value {d:.1}", .{xft_dpi});
    }

    const geometry_dpi = calcDpiFromGeometry(screen);
    if (isReasonableDpi(geometry_dpi)) {
        debug.info("Using geometry-calculated DPI: {d:.1}", .{geometry_dpi});
    } else {
        debug.warn("Calculated DPI {d:.1} seems unreasonable, using baseline DPI", .{geometry_dpi});
    }

    return if (isReasonableDpi(geometry_dpi)) geometry_dpi else BASELINE_DPI;
}

fn isReasonableDpi(dpi: f32) bool {
    return std.math.isFinite(dpi) and dpi >= MIN_REASONABLE_DPI and dpi <= MAX_REASONABLE_DPI;
}

/// Scale a border or gap value. Percentages are screen-relative and applied
/// as-is (no global scale, or HiDPI displays would get double-scaled);
/// absolute pixel values pass through unchanged.
/// See utils.scaling.scaleBorderWidth, the shared source of truth.
pub fn scaleBorderWidth(value: parser.ScalableValue, reference_dimension: u16) u16 {
    return utils.scaling.scaleBorderWidth(value, reference_dimension);
}

/// Returns the master width as a fraction (0.0–1.0) for percentage values,
/// or as a negative float encoding an absolute pixel value otherwise
/// (callers should treat negative results as `@abs(result)` pixels).
/// See utils.scaling.scaleMasterWidth, the shared source of truth.
pub fn scaleMasterWidth(value: parser.ScalableValue) f32 {
    return utils.scaling.scaleMasterWidth(value);
}

/// Scales a font size value against the screen height, clamped to a minimum of 1px.
/// Percentage values are relative to FONT_BASELINE_HEIGHT (1080px) rather than the
/// screen baseline, so font sizes degrade more gracefully on smaller screens.
pub fn scaleFontSize(value: parser.ScalableValue, screen: *xcb.xcb_screen_t) u16 {
    const screen_height: f32 = @floatFromInt(screen.height_in_pixels);
    const raw = if (value.is_percentage) value.value * (screen_height / FONT_BASELINE_HEIGHT) else value.value;
    const clamped = std.math.clamp(@round(raw), 1.0, @as(f32, std.math.maxInt(u16)));
    return @intFromFloat(clamped);
}

/// Converts a scalable bar height value to pixels, clamped to BAR_MIN_HEIGHT_PX.
pub fn scaleBarHeight(value: parser.ScalableValue, screen_height: u16) u16 {
    const screen_height_f: f32 = @floatFromInt(screen_height);
    const scaled_px: f32 = utils.scaling.scaleToPixels(value, screen_height_f);
    const clamped = std.math.clamp(@round(scaled_px), 0.0, @as(f32, std.math.maxInt(u16)));
    return @max(BAR_MIN_HEIGHT_PX, @as(u16, @intFromFloat(clamped)));
}

// Refresh-rate detection
//
// The carousel ticks once per display refresh so its scrolling blits align
// with the monitor's frame cadence: too fast wastes the compositor's dropped
// frames (higher rates than the display can show), too slow makes fast scroll
// look choppy. The rate is therefore queried from the RandR protocol
// extension — the pixel clock of the currently-active mode divided by its
// total dimensions — rather than assumed.
//
// The detected rate is published to an atomic that the carousel thread reads
// lock-free via `getDetectedRateHz`. When the monitor re-configures (xrandr
// mode change, hotplug, rate switch), the X server delivers RandR notify
// events to the root window; the main thread's event loop re-runs the query
// and the carousel picks the new rate up on its very next wake.
//
// The first call is a one-time blocking setup on the main thread (a handful
// of round trips) — every later call is a no-op, keeping the per-draw call in
// title.zig free. `getDetectedRateHz` and `randrFirstEvent` stay
// side-effect-free and lock-free so the carousel thread never touches the X
// connection.

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
/// call from the main thread on every draw — the actual setup runs once and
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
/// change, output change — the only masks this module subscribes to).
/// Re-detects the active refresh rate so the carousel cadence tracks monitor
/// re-configuration. Main thread only.
pub fn handleRandrNotifyEvent(conn: *xcb.xcb_connection_t) void {
    // A single mode switch floods several notify events back-to-back (screen
    // size + CRTC + output change). They all describe the same new
    // configuration, so collapse them into one re-detection per burst.
    const now = utils.monotonicNs();
    if (now -| last_redetect_ns < min_redetect_interval_ns) return;
    last_redetect_ns = now;
    detectRefreshRate(conn, core.getState().root);
}

/// Resolves the RandR extension's server-assigned event base and enables the
/// notify events that drive re-detection. Returns false when RandR is absent
/// or unusable. The subscription happens exactly once at startup — every
/// re-detection is a pure read-only query, so it can never re-arm or amplify
/// the very events it reacts to.
fn setupRandr(conn: *xcb.xcb_connection_t, root: xcb.xcb_window_t) bool {
    // Resolve the extension's event base by name (avoids the opaque
    // `xcb_randr_id` extern, which Zig cannot reference).
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
/// rate. Falls back to `default_hz` (already the atomic's initial value) on
/// any failure.
fn detectRefreshRate(conn: *xcb.xcb_connection_t, root: xcb.xcb_window_t) void {
    const res_cookie = xcb.xcb_randr_get_screen_resources_current(conn, root);
    const res = xcb.xcb_randr_get_screen_resources_current_reply(conn, res_cookie, null) orelse return;
    defer std.c.free(res);

    if (refreshRateFromOutputs(conn, root, res)) |rate| publishDetectedRate(rate);
}

/// Returns the refresh rate of the mode active on the screen's primary output
/// (falling back to the first connected, active output), or null when nothing
/// usable is found.
fn refreshRateFromOutputs(
    conn: *xcb.xcb_connection_t,
    root: xcb.xcb_window_t,
    res: *xcb.xcb_randr_get_screen_resources_current_reply_t,
) ?f64 {
    // Preferred: the primary output. The request returns an error on servers
    // predating RandR 1.3, in which case the reply is null and output stays 0.
    var primary: xcb.xcb_randr_output_t = 0;
    const primary_cookie = xcb.xcb_randr_get_output_primary(conn, root);
    if (xcb.xcb_randr_get_output_primary_reply(conn, primary_cookie, null)) |reply| {
        defer std.c.free(reply);
        primary = reply.*.output;
    }

    if (primary != 0) if (refreshRateFromOutput(conn, primary, res)) |rate| return rate;

    const outputs = xcb.xcb_randr_get_screen_resources_current_outputs(res);
    const output_count: usize = @intCast(xcb.xcb_randr_get_screen_resources_current_outputs_length(res));
    var i: usize = 0;
    while (i < output_count) : (i += 1) {
        const output = outputs[i];
        if (output == primary) continue;
        if (refreshRateFromOutput(conn, output, res)) |rate| return rate;
    }
    return null;
}

/// Returns the refresh rate of the mode currently active on `output`, or null
/// when the output is disconnected or inactive (no CRTC/mode).
fn refreshRateFromOutput(
    conn: *xcb.xcb_connection_t,
    output: xcb.xcb_randr_output_t,
    res: *const xcb.xcb_randr_get_screen_resources_current_reply_t,
) ?f64 {
    const out_cookie = xcb.xcb_randr_get_output_info(conn, output, res.*.config_timestamp);
    const out = xcb.xcb_randr_get_output_info_reply(conn, out_cookie, null) orelse return null;
    defer std.c.free(out);
    const crtc = out.*.crtc;
    if (crtc == 0) return null; // Output not driven by any CRTC.

    const crtc_cookie = xcb.xcb_randr_get_crtc_info(conn, crtc, res.*.config_timestamp);
    const crtc_info = xcb.xcb_randr_get_crtc_info_reply(conn, crtc_cookie, null) orelse return null;
    defer std.c.free(crtc_info);
    const mode_id = crtc_info.*.mode;
    if (mode_id == 0) return null; // CRTC enabled but no mode.

    // Match the active mode against the screen resources and derive its rate
    // from the pixel clock: rate = dot_clock / (htotal * vtotal).
    const modes = xcb.xcb_randr_get_screen_resources_current_modes(res);
    const mode_count: usize = @intCast(xcb.xcb_randr_get_screen_resources_current_modes_length(res));
    var i: usize = 0;
    while (i < mode_count) : (i += 1) {
        const mode = modes[i];
        if (mode.id != mode_id) continue;
        if (mode.htotal == 0 or mode.vtotal == 0) return null;
        return @as(f64, @floatFromInt(mode.dot_clock)) /
            (@as(f64, @floatFromInt(mode.htotal)) * @as(f64, @floatFromInt(mode.vtotal)));
    }
    return null;
}

/// Publishes `rate` to the atomic read by the carousel thread, rejecting
/// non-finite or out-of-band readings so the wake interval stays sane.
fn publishDetectedRate(rate: f64) void {
    if (std.math.isFinite(rate) and rate >= MIN_SANE_HZ and rate <= MAX_SANE_HZ) {
        detected_rate_hz.store(rate, .monotonic);
        debug.info("Detected monitor refresh rate: {d:.2} Hz", .{rate});
    } else {
        debug.warn("Detected invalid refresh rate {d:.2} Hz, keeping fallback", .{rate});
    }
}

/// Enables RandR notify events on the root window: screen size changes (rate
/// switches via xrandr included), CRTC changes, and output changes (hotplug).
/// Idempotent — re-selecting on each notify is harmless and keeps the mask
/// in place even if another client narrowed it.
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
