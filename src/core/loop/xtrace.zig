//! Opt-in per-window X11 event tracing: logs event order for watched windows
//! (interleaved with WM requests) to diagnose client/WM protocol issues.
//! Enabled via `HANA_XTRACE=...` or `HANA_XTRACE=*`; zero cost when disabled.

const std = @import("std");
const log = @import("log");

/// Arming state: null = not yet resolved from the environment. Resolving it
/// lazily keeps getenv off the hot path for the common (disabled) case while
/// still costing a single null check per call.
var watch: ?[]const u32 = null;
var armed: bool = false;

/// Reads `HANA_XTRACE` once. `*` arms every window (recorded as an empty
/// watch list, which `watches` reports as always-true); a comma-separated list
/// of decimal or 0x-prefixed ids arms exactly those.
fn resolve() void {
    if (armed) return;
    armed = true;
    const raw_z = std.c.getenv("HANA_XTRACE") orelse return;
    const raw = std.mem.span(raw_z);
    if (raw.len == 0) return;
    if (std.mem.eql(u8, raw, "*")) {
        watch = &[_]u32{};
        return;
    }
    var ids: std.ArrayList(u32) = .empty;
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " \t");
        if (t.len == 0) continue;
        const v = std.fmt.parseInt(u32, t, 0) catch continue;
        ids.append(gpa, v) catch return;
    }
    watch = ids.toOwnedSlice(gpa) catch &[_]u32{};
}

const gpa = std.heap.c_allocator;

/// True when tracing is armed at all. The hot-path guard: call sites check
/// this before touching anything else, so the disabled cost is one compare
/// against a bool that never changes after the first traced event.
pub fn enabled() bool {
    if (watch == null) resolve();
    return watch != null;
}

/// True when `win` should be traced. An empty watch list means "all".
pub fn watches(win: u32) bool {
    if (watch == null) resolve();
    const w = watch orelse return false;
    if (w.len == 0) return true;
    for (w) |id| if (id == win) return true;
    return false;
}

/// The X11 event name for a response type byte, so the log is readable
/// without keeping an xev session open alongside.
/// Event name for the raw type byte. Bit 7 (XCB's SendEvent flag) is stripped
/// first: an EWMH _NET_WM_STATE request arrives as 33 | 0x80, and naming the
/// raw byte printed "Other" for every one of them, which is why a trace aimed
/// at browser fullscreen requests appeared to see no ClientMessage at all.
fn name(t: u8) []const u8 {
    return switch (t & 0x7f) {
        2 => "KeyPress",
        3 => "KeyRelease",
        4 => "ButtonPress",
        5 => "ButtonRelease",
        6 => "MotionNotify",
        7 => "EnterNotify",
        8 => "LeaveNotify",
        9 => "FocusIn",
        10 => "FocusOut",
        11 => "KeymapNotify",
        12 => "Expose",
        13 => "GraphicsExposure",
        14 => "NoExposure",
        15 => "VisibilityNotify",
        16 => "CreateNotify",
        17 => "DestroyNotify",
        18 => "UnmapNotify",
        19 => "MapNotify",
        20 => "MapRequest",
        21 => "ReparentNotify",
        22 => "ConfigureNotify",
        23 => "ConfigureRequest",
        24 => "GravityNotify",
        25 => "ResizeRequest",
        26 => "CirculateNotify",
        27 => "CirculateRequest",
        28 => "PropertyNotify",
        29 => "SelectionClear",
        30 => "SelectionRequest",
        31 => "SelectionNotify",
        32 => "ColormapNotify",
        33 => "ClientMessage",
        34 => "MappingNotify",
        else => "Other",
    };
}

/// Logs one inbound event for `win`. The caller has already decided the
/// event belongs to a watched window, so this does no filtering itself.
pub fn inbound(t: u8, win: u32) void {
    log.info("[xtrace] {s} win=0x{x}", .{ name(t), win });
}

/// Logs a request hana is about to send. `what` names the operation and `arg`
/// carries whatever the caller already has formatted (a rect, a stack mode, an
/// empty string). Recorded BEFORE the request so the log order matches the
/// order the server sees, not the order the socket flushes.
pub fn outbound(win: u32, what: []const u8, arg: []const u8) void {
    log.info("[xtrace] -> {s} win=0x{x} {s}", .{ what, win, arg });
}

/// One-shot banner so a trace run is identifiable in a mixed log.
pub fn announce() void {
    if (watch == null) resolve();
    if (watch == null) return;
    log.info("[xtrace] armed: {s}", .{
        if (watch.?.len == 0) "*" else "explicit id list",
    });
}
