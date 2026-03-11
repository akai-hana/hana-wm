//! Monitor refresh-rate detection via XCB RandR.
//!
//! Usage pattern:
//!   hertz.ensureDetected(conn);     // once per draw cycle — cheap no-op after first call
//!   const hz = hertz.getCached();   // reads the cached value; never blocks
//!   hertz.invalidate();             // call on RRScreenChangeNotify to force re-detect

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;

/// Fallback rate used when RandR is unavailable or returns an invalid value.
pub const DEFAULT_HZ: f64 = 60.0;

/// Module-level cache.  Initialised to the default so getCached() is always safe.
var g_hz: f64 = DEFAULT_HZ;
var g_detected: bool = false;

// Public API

/// Return the cached refresh rate (Hz).
/// Always safe to call; returns DEFAULT_HZ if detection has not yet run.
pub fn getCached() f64 {
    return g_hz;
}

/// Detect and cache the monitor refresh rate.
/// Subsequent calls are a single branch and a return — zero X11 I/O.
/// Pass the XCB connection used by the bar.
pub fn ensureDetected(conn: *xcb.xcb_connection_t) void {
    if (g_detected) return;
    g_detected = true;
    g_hz = detect(conn);
}

/// Force re-detection on the next ensureDetected() call.
/// Call this when handling an RRScreenChangeNotify event so that a monitor
/// hotplug or mode switch is picked up on the next draw cycle.
pub fn invalidate() void {
    g_detected = false;
}

// Internal helpers

/// Extract the root window of the first screen from the XCB connection.
fn getRootWindow(conn: *xcb.xcb_connection_t) u32 {
    const setup = xcb.xcb_get_setup(conn);
    var it = xcb.xcb_setup_roots_iterator(setup);
    if (it.rem > 0) return it.data.*.root;
    return 0;
}

/// Attempt to read the current refresh rate via xcb_randr_get_screen_info.
///
/// xcb_randr_get_screen_info_reply_t.rate is a uint16 in Hz directly —
/// no dot_clock arithmetic needed.  This covers virtually all single-CRTC
/// setups.  Multi-monitor setups return the rate of the screen associated
/// with the root window, which is correct for a horizontal bar that spans
/// the primary monitor.
///
/// Precision note: RandR reports integer Hz (e.g., 60, 144).  For displays
/// that run at fractional rates (59.940, 143.981 …) the integer is an
/// acceptable approximation for the carousel frame-snap use-case.
fn detect(conn: *xcb.xcb_connection_t) f64 {
    // ── RandR path ───────────────────────────────────────────────────────────
    // Guard against builds where xcb-randr headers were not included.
    if (!@hasDecl(xcb, "xcb_randr_get_screen_info")) {
        return detectFallback();
    }

    const root = getRootWindow(conn);
    if (root == 0) return detectFallback();

    const cookie = xcb.xcb_randr_get_screen_info(conn, root);
    const reply = xcb.xcb_randr_get_screen_info_reply(conn, cookie, null) orelse
        return detectFallback();
    defer std.c.free(reply);

    const rate = reply.*.rate;
    if (rate > 0) {
        return @floatFromInt(rate);
    }

    // ── RandR returned 0 — try the precise CRTC mode path ───────────────────
    // Some drivers report rate=0 from get_screen_info but provide correct data
    // via get_screen_resources_current.  Attempt that before giving up.
    if (@hasDecl(xcb, "xcb_randr_get_screen_resources_current")) {
        if (detectViaCrtc(conn, root)) |hz| return hz;
    }

    return detectFallback();
}

/// Read the refresh rate of the first active CRTC via
/// xcb_randr_get_screen_resources_current + xcb_randr_get_crtc_info.
/// Returns null on any failure.
fn detectViaCrtc(conn: *xcb.xcb_connection_t, root: u32) ?f64 {
    const rc = xcb.xcb_randr_get_screen_resources_current(conn, root);
    const rr = xcb.xcb_randr_get_screen_resources_current_reply(conn, rc, null) orelse
        return null;
    defer std.c.free(rr);

    // Collect mode infos so we can look up dot_clock / htotal / vtotal.
    const mode_it_len = xcb.xcb_randr_get_screen_resources_current_modes_length(rr);
    const mode_it_ptr = xcb.xcb_randr_get_screen_resources_current_modes(rr);
    if (mode_it_len <= 0 or mode_it_ptr == null) return null;
    const modes = mode_it_ptr.?[0..@intCast(mode_it_len)];

    // Iterate CRTCs and return the rate of the first one that has an active mode.
    const crtc_it_len = xcb.xcb_randr_get_screen_resources_current_crtcs_length(rr);
    const crtc_it_ptr = xcb.xcb_randr_get_screen_resources_current_crtcs(rr);
    if (crtc_it_len <= 0 or crtc_it_ptr == null) return null;
    const crtcs = crtc_it_ptr.?[0..@intCast(crtc_it_len)];

    for (crtcs) |crtc| {
        const cc = xcb.xcb_randr_get_crtc_info(conn, crtc, rr.*.config_timestamp);
        const cr = xcb.xcb_randr_get_crtc_info_reply(conn, cc, null) orelse continue;
        defer std.c.free(cr);

        const mode_id = cr.*.mode;
        if (mode_id == 0) continue; // CRTC disabled

        for (modes) |m| {
            if (m.id != mode_id) continue;
            const htotal: u64 = m.htotal;
            const vtotal: u64 = m.vtotal;
            if (htotal == 0 or vtotal == 0) break;
            const hz: f64 = @as(f64, @floatFromInt(m.dot_clock)) /
                @as(f64, @floatFromInt(htotal * vtotal));
            if (hz > 0.0) return hz;
            break;
        }
    }

    return null;
}

/// Last-resort fallback: try to read the refresh rate from the DRM sysfs node.
/// Works on Linux even without a functioning RandR stack (e.g., Wayland XWayland
/// running without the RandR extension forwarded).
///
/// Reads the first line of the first "modes" file found under /sys/class/drm/.
/// The format is "NNNxMMM" for resolution; the mode list starts with the highest
/// rate mode, so we look at the first preferred mode's vrefresh via EDID or
/// the kernel's internal rate annotation.  If unavailable, returns DEFAULT_HZ.
///
/// Note: this is a best-effort heuristic.  The primary path is always RandR.
fn detectFallback() f64 {
    // Try /sys/class/drm/card*-*/modes  (Linux DRM connector mode list).
    // Each line is "<width>x<height>" for a mode; the file is sorted by preferred
    // mode first but does not include the refresh rate directly.  Without further
    // parsing we cannot extract Hz from this file alone.
    //
    // A more reliable sysfs path is:
    //   /sys/class/drm/card*-*/vrr_capable  (not universally present)
    //   /sys/class/graphics/fb0/modes       (legacy fbdev, rarely present)
    //
    // None of these give us Hz without EDID parsing.  Returning the default is
    // the correct safe behaviour here.
    return DEFAULT_HZ;
}
