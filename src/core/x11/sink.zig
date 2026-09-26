//! The send seam: the interface every optional subsystem emits requests
//! through, and its one production implementation.
//!
//! `Sink` (the vtable) lives HERE, beside the shims that implement it, rather
//! than in the reconciler that consumes it. It used to be declared in
//! `sync.zig`, which made this low-level implementation import the high-level
//! planner just to name the type it implements -- an inversion. Requests are
//! planned in `reconcile.zig` and dispatched by the shims in this file (the
//! sanctioned seam where raw XCB calls are allowed: a few shims stay inline
//! rather than forcing every primitive through `requests.zig`, and the
//! check-layers allowlist covers this file). Each shim wraps the exact request
//! pattern it consolidates here:
//!   geom          ~ requests.configureWindow (plus the atomic raise variant
//!                   that merges a stack mode into the same request)
//!   borderWidth   ~ borders.applyWidth's send (dedup lives in LastSent);
//!                   inline xcb_configure_window in this seam
//!   borderPixel   ~ requests.setBorderPixel
//!   park          ~ X-offscreen + BELOW merged into one request
//!   stackOnly     ~ requests.raiseWindow (ABOVE; the only stack mode)
//!   setEwmhFullscreen ~ xcb_change_property (_NET_WM_STATE_FULLSCREEN)
//!   flush/grab    ~ conn.flush / requests.grabServer / ungrabAndFlush

const std = @import("std");
const core = @import("core");
const xcb = core.xcb;
const constants = @import("constants");
const log = @import("log");

const model = @import("model");
const geometry = @import("geom");
const requests = @import("requests");
/// Stacking mode vocabulary for a request. `above` is currently the only mode
/// the WM emits.
pub const Stack = enum { above };

/// Request sink: the output port every placement decision writes through.
/// Production wires `XcbSink`; tests wire a recorder, which is the whole point
/// of the vtable. One batch = everything queued between caller flushes (xcb
/// buffers requests; the CALLER decides when to flush).
pub const Sink = struct {
    ptr: *anyopaque,
    vt: *const VTable,

    pub const VTable = struct {
        map: *const fn (*anyopaque, model.WindowId) void,
        geom: *const fn (*anyopaque, model.WindowId, geometry.Rect, ?Stack) void,
        geom_bordered: *const fn (*anyopaque, model.WindowId, geometry.Rect, u16, ?Stack) void,
        border_width: *const fn (*anyopaque, model.WindowId, u16) void,
        border_pixel: *const fn (*anyopaque, model.WindowId, u32) void,
        park: *const fn (*anyopaque, model.WindowId) void,
        stack_only: *const fn (*anyopaque, model.WindowId, Stack) void,
        set_ewmh_fullscreen: *const fn (*anyopaque, model.WindowId, u32, u32, bool) void,
        flush: *const fn (*anyopaque) void,
        grab_server: *const fn (*anyopaque) void,
        ungrab_and_flush: *const fn (*anyopaque) void,
    };

    pub inline fn map(self: Sink, win: model.WindowId) void {
        self.vt.map(self.ptr, win);
    }
    pub inline fn geom(self: Sink, win: model.WindowId, rect: geometry.Rect, stack: ?Stack) void {
        self.vt.geom(self.ptr, win, rect, stack);
    }
    /// Geometry + border width merged into one configure request; the shape a
    /// workspace switch emits for every arriving window.
    pub inline fn geomBordered(self: Sink, win: model.WindowId, rect: geometry.Rect, bw: u16, stack: ?Stack) void {
        self.vt.geom_bordered(self.ptr, win, rect, bw, stack);
    }
    pub inline fn borderWidth(self: Sink, win: model.WindowId, bw: u16) void {
        self.vt.border_width(self.ptr, win, bw);
    }
    pub inline fn borderPixel(self: Sink, win: model.WindowId, pixel: u32) void {
        self.vt.border_pixel(self.ptr, win, pixel);
    }
    pub inline fn park(self: Sink, win: model.WindowId) void {
        self.vt.park(self.ptr, win);
    }
    pub inline fn stackOnly(self: Sink, win: model.WindowId, s: Stack) void {
        self.vt.stack_only(self.ptr, win, s);
    }
    pub inline fn setEwmhFullscreen(self: Sink, win: model.WindowId, state_atom: u32, fs_atom: u32, is_fullscreen: bool) void {
        self.vt.set_ewmh_fullscreen(self.ptr, win, state_atom, fs_atom, is_fullscreen);
    }
    pub inline fn flush(self: Sink) void {
        self.vt.flush(self.ptr);
    }
    pub inline fn grabServer(self: Sink) void {
        self.vt.grab_server(self.ptr);
    }
    pub inline fn ungrabAndFlush(self: Sink) void {
        self.vt.ungrab_and_flush(self.ptr);
    }
};

pub const XcbSink = struct {
    conn: core.Connection,

    pub fn sink(self: *XcbSink) Sink {
        return .{
            .ptr = self,
            .vt = &xcb_vtable,
        };
    }

    inline fn fromPtr(ptr: *anyopaque) *XcbSink {
        return @ptrCast(@alignCast(ptr));
    }

    fn mapShim(ptr: *anyopaque, win: u32) void {
        _ = xcb.xcb_map_window(XcbSink.fromPtr(ptr).conn, win);
    }

    /// Configure X|Y|W|H, merging a stack mode into the SAME request when
    /// one is requested (never a separate round of requests for geometry+raise).
    fn geomShim(ptr: *anyopaque, win: u32, rect: geometry.Rect, stack: ?Stack) void {
        requests.configureWindow(
            XcbSink.fromPtr(ptr).conn,
            win,
            rect,
            if (stack) |s| stackMode(s) else null,
            null,
        );
    }

    /// Geometry + border-width in ONE configure: the common workspace-switch
    /// shape (an arriving window re-sends both), so the two go out as a single
    /// request instead of two round trips of the config queue.
    fn geomBorderedShim(ptr: *anyopaque, win: u32, rect: geometry.Rect, bw: u16, stack: ?Stack) void {
        requests.configureWindow(
            XcbSink.fromPtr(ptr).conn,
            win,
            rect,
            if (stack) |s| stackMode(s) else null,
            bw,
        );
    }

    fn borderWidthShim(ptr: *anyopaque, win: u32, bw: u16) void {
        _ = xcb.xcb_configure_window(
            XcbSink.fromPtr(ptr).conn,
            win,
            xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH,
            &[_]u32{bw},
        );
    }

    fn borderPixelShim(ptr: *anyopaque, win: u32, pixel: u32) void {
        requests.setBorderPixel(XcbSink.fromPtr(ptr).conn, win, pixel);
    }

    /// Park = offscreen X + stack BELOW in ONE configure_window.
    fn parkShim(ptr: *anyopaque, win: u32) void {
        _ = xcb.xcb_configure_window(
            XcbSink.fromPtr(ptr).conn,
            win,
            xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_STACK_MODE,
            &[_]u32{
                @bitCast(constants.offscreen_x_position),
                xcb.XCB_STACK_MODE_BELOW,
            },
        );
    }

    fn stackOnlyShim(ptr: *anyopaque, win: u32, s: Stack) void {
        switch (s) {
            .above => requests.raiseWindow(XcbSink.fromPtr(ptr).conn, win),
        }
    }

    /// Set/clear `fs_atom` in the `_NET_WM_STATE` list on `win` while PRESERVING
    /// any other atoms already listed (a REPLACE that writes only the fullscreen
    /// atom would nuke e.g. _NET_WM_STATE_ABOVE/_STICKY the client set). One
    /// blocking get_property round-trip then one replace-mode change_property;
    /// only reachable from a fullscreen toggle, so the round-trip is acceptable.
    ///
    /// The read buffer is bounded, so a list longer than `max_ewmh_states`
    /// would be silently TRUNCATED by the REPLACE (dropping the client's other
    /// state atoms). We detect that via `bytes_after != 0` and bail out without
    /// touching the property rather than corrupting it.
    const max_ewmh_states = 64;

    fn setEwmhFullscreenShim(
        ptr: *anyopaque,
        win: u32,
        state_atom: u32,
        fs_atom: u32,
        is_fullscreen: bool,
    ) void {
        const conn = XcbSink.fromPtr(ptr).conn;

        var state_atoms: [max_ewmh_states]u32 = undefined;
        var count: usize = 0;
        const get_cookie = xcb.xcb_get_property(conn, 0, win, state_atom, xcb.XCB_ATOM_ATOM, 0, state_atoms.len);
        if (xcb.xcb_get_property_reply(conn, get_cookie, null)) |reply| {
            defer std.c.free(reply);
            if (reply.*.format == 32 and reply.*.type == xcb.XCB_ATOM_ATOM) {
                // More atoms on the wire than we can preserve: rewriting would
                // drop them. Leave the property alone.
                if (reply.*.bytes_after != 0) {
                    log.warn("_NET_WM_STATE on 0x{x} exceeds {d} atoms; skipping fullscreen update", .{ win, max_ewmh_states });
                    return;
                }
                const raw = xcb.xcb_get_property_value(reply) orelse return;
                const n: usize = @intCast(reply.*.value_len);
                const existing = @as([*]const u32, @ptrCast(@alignCast(raw)))[0..@min(n, state_atoms.len)];
                for (existing) |a| {
                    if (a == fs_atom or a == 0) continue;
                    state_atoms[count] = a;
                    count += 1;
                }
            }
        }
        if (is_fullscreen and count < state_atoms.len) {
            state_atoms[count] = fs_atom;
            count += 1;
        }

        _ = xcb.xcb_change_property(
            conn,
            xcb.XCB_PROP_MODE_REPLACE,
            win,
            state_atom,
            xcb.XCB_ATOM_ATOM,
            32,
            @intCast(count),
            if (count > 0) &state_atoms else null,
        );
    }

    fn flushShim(ptr: *anyopaque) void {
        _ = xcb.xcb_flush(XcbSink.fromPtr(ptr).conn);
    }

    fn grabShim(ptr: *anyopaque) void {
        requests.grabServer(XcbSink.fromPtr(ptr).conn);
    }

    fn ungrabAndFlushShim(ptr: *anyopaque) void {
        requests.ungrabAndFlush(XcbSink.fromPtr(ptr).conn);
    }
};

/// Shared vtable for the production sink: one const instead of re-inlining the
/// shim table in every XcbSink::sink() call.
const xcb_vtable: Sink.VTable = .{
    .map = XcbSink.mapShim,
    .geom = XcbSink.geomShim,
    .geom_bordered = XcbSink.geomBorderedShim,
    .border_width = XcbSink.borderWidthShim,
    .border_pixel = XcbSink.borderPixelShim,
    .park = XcbSink.parkShim,
    .stack_only = XcbSink.stackOnlyShim,
    .set_ewmh_fullscreen = XcbSink.setEwmhFullscreenShim,
    .flush = XcbSink.flushShim,
    .grab_server = XcbSink.grabShim,
    .ungrab_and_flush = XcbSink.ungrabAndFlushShim,
};

inline fn stackMode(s: Stack) u32 {
    return switch (s) {
        .above => xcb.XCB_STACK_MODE_ABOVE,
    };
}
