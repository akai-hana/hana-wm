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
//!   map           ~ xcb_map_window (fresh window before its park)
//!   configure     ~ one xcb_configure_window; the mask is assembled from
//!                   the Configure fields, with the stack mode merged into
//!                   the same request when it changed
//!   borderPixel   ~ requests.setBorderPixel
//!   park          ~ X-offscreen + BELOW merged into one request
//!   stackOnly     ~ requests.raiseWindow (ABOVE; the only stack mode)
//!   setStateAtom  ~ read-merge-write of one _NET_WM_STATE atom list
//!   flush/grab    ~ conn.flush / requests.grabServer / ungrabAndFlush

const std = @import("std");
const core = @import("core");
const xcb = core.xcb;
const constants = @import("constants");
const log = @import("log");

const model = @import("model");
const requests = @import("requests");
/// Stacking mode vocabulary for a request. `above` is currently the only mode
/// the WM emits.
pub const Stack = enum { above };

/// The X11 wire form of one configure: a value array whose slots are ordered
/// by the protocol (X, Y, WIDTH, HEIGHT, BORDER_WIDTH, STACK_MODE) plus the
/// mask naming the live ones. X consumes value slots by mask bit, so the array
/// is always full width and only the mask varies -- which is exactly why the
/// slot order is positional magic and worth testing directly.
const ConfigureWire = struct { mask: u16, values: [6]u32 };

/// Assembles the configure request body. Split out of the shim so the slot
/// order is assertable without an X connection: swapping slots 2 and 3 sends
/// width as height, which X accepts and the WM discovers as every window
/// rendered at the wrong aspect.
pub fn configureWire(c: Configure) ConfigureWire {
    var mask: u16 = 0;
    var values = [_]u32{ 0, 0, 0, 0, 0, 0 };
    if (c.rect) |r| {
        mask |= xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
            xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT;
        values[0] = model.toXcbCoord(r.x);
        values[1] = model.toXcbCoord(r.y);
        values[2] = r.width;
        values[3] = r.height;
    }
    if (c.bw) |bw| {
        mask |= xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH;
        values[4] = bw;
    }
    if (c.stack) |s| {
        mask |= xcb.XCB_CONFIG_WINDOW_STACK_MODE;
        values[5] = stackMode(s);
    }
    return .{ .mask = mask, .values = values };
}

/// One configure request, described by which parts of the window are changing.
/// A null field means "leave it alone" -- X's own semantics for an unset
/// configure mask bit, expressed instead of implied by which shim was called.
pub const Configure = struct {
    rect: ?model.Rect = null,
    bw: ?u16 = null,
    stack: ?Stack = null,
};

/// Request sink: the output port every placement decision writes through.
/// Production wires `XcbSink`; tests wire a recorder, which is the whole point
/// of the vtable. One batch = everything queued between caller flushes (xcb
/// buffers requests; the CALLER decides when to flush).
pub const Sink = struct {
    ptr: *anyopaque,
    vt: *const VTable,

    const VTable = struct {
        map: *const fn (*anyopaque, model.WindowId) void,
        configure: *const fn (*anyopaque, model.WindowId, Configure) void,
        border_pixel: *const fn (*anyopaque, model.WindowId, u32) void,
        park: *const fn (*anyopaque, model.WindowId) void,
        stack_only: *const fn (*anyopaque, model.WindowId, Stack) void,
        set_state_atom: *const fn (*anyopaque, model.WindowId, u32, u32, bool) void,
        flush: *const fn (*anyopaque) void,
        grab_server: *const fn (*anyopaque) void,
        ungrab_and_flush: *const fn (*anyopaque) void,
    };

    pub inline fn map(self: Sink, win: model.WindowId) void {
        self.vt.map(self.ptr, win);
    }
    /// Describe WHAT changed; the shim decides how many X bits that is. There
    /// is no way for a caller to ask for "geometry and border width" as two
    /// requests, which is the invariant the old `geom` + `geom_bordered` +
    /// `border_width` trio had to be argued into at every call site.
    pub inline fn configure(self: Sink, win: model.WindowId, c: Configure) void {
        self.vt.configure(self.ptr, win, c);
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
    /// Add (`add`) or remove (`!add`) one `_NET_WM_STATE` atom on `win`,
    /// preserving every other atom in the list. Generalized from the
    /// fullscreen-only shim (5.5): the read-merge-replace dance is list
    /// editing, and nothing about it is specific to fullscreen.
    pub inline fn setStateAtom(self: Sink, win: model.WindowId, state_atom: u32, atom: u32, add: bool) void {
        self.vt.set_state_atom(self.ptr, win, state_atom, atom, add);
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

    fn configureShim(ptr: *anyopaque, win: u32, c: Configure) void {
        const w = configureWire(c);
        // Nothing to say: an all-zero mask is a no-op request at best and a
        // protocol error at worst, so drop it rather than send it.
        if (w.mask == 0) return;
        _ = xcb.xcb_configure_window(XcbSink.fromPtr(ptr).conn, win, w.mask, &w.values);
    }

    fn borderPixelShim(ptr: *anyopaque, win: u32, pixel: u32) void {
        requests.setBorderPixel(XcbSink.fromPtr(ptr).conn, win, pixel);
    }

    /// Park = offscreen X + stack BELOW in ONE configure_window.
    ///
    /// Deliberately NOT folded into `configure`, even though that is now a
    /// general "one configure, any combination" slot. Park asserts X only:
    /// configure_window leaves unset mask bits alone, so sliding a window
    /// offscreen costs one coordinate, whereas a `Configure.rect` would assert
    /// Y/WIDTH/HEIGHT too and MOVE/RESIZE the window to whatever the caller
    /// believed its geometry was. The park call site does not have a trustworthy
    /// current rect to assert (it is the branch for a window that has never
    /// been sent geometry), so collapsing this would turn a pure hide into a
    /// speculative move. Keeping it separate is what makes that impossible.
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

    /// Add/remove `atom` in the `_NET_WM_STATE` list on `win` while PRESERVING
    /// any other atoms already listed (a REPLACE that writes only the one atom
    /// would nuke e.g. _NET_WM_STATE_ABOVE/_STICKY the client set). One
    /// blocking get_property round-trip then one replace-mode change_property;
    /// only reachable from a state-atom toggle, so the round-trip is acceptable.
    ///
    /// The read buffer is bounded, so a list longer than `max_ewmh_states`
    /// would be silently TRUNCATED by the REPLACE (dropping the client's other
    /// state atoms). We detect that via `bytes_after != 0` and bail out without
    /// touching the property rather than corrupting it.
    const max_ewmh_states = 64;

    /// Set / clear `atom` on `_NET_WM_STATE` for `win`, preserving the rest of
    /// the list. A no-op (nothing is written) when the atom's presence already
    /// matches the request -- a strictness the REPLACE path owed the client:
    /// it unconditionally sent the merged list, firing a PropertyNotify with a
    /// (possibly re-ordered) value for a semantically unchanged state.
    fn setStateAtomShim(
        ptr: *anyopaque,
        win: u32,
        state_atom: u32,
        atom: u32,
        add: bool,
    ) void {
        const conn = XcbSink.fromPtr(ptr).conn;

        var state_atoms: [max_ewmh_states]u32 = undefined;
        var count: usize = 0;
        var has_atom = false;
        const get_cookie = xcb.xcb_get_property(conn, 0, win, state_atom, xcb.XCB_ATOM_ATOM, 0, state_atoms.len);
        if (xcb.xcb_get_property_reply(conn, get_cookie, null)) |reply| {
            defer std.c.free(reply);
            if (reply.*.format == 32 and reply.*.type == xcb.XCB_ATOM_ATOM) {
                // More atoms on the wire than we can preserve: rewriting would
                // drop them. Leave the property alone.
                if (reply.*.bytes_after != 0) {
                    log.warn("_NET_WM_STATE on 0x{x} exceeds {d} atoms; skipping state-atom update", .{ win, max_ewmh_states });
                    return;
                }
                const raw = xcb.xcb_get_property_value(reply) orelse return;
                const n: usize = @intCast(reply.*.value_len);
                const existing = @as([*]const u32, @ptrCast(@alignCast(raw)))[0..@min(n, state_atoms.len)];
                for (existing) |a| {
                    if (a == atom) {
                        has_atom = true;
                        continue;
                    }
                    if (a == 0) continue;
                    state_atoms[count] = a;
                    count += 1;
                }
            }
        }

        // What the request intends to change about `atom`'s membership. Adding
        // one the list already carries (or removing one it never had) leaves
        // the property value identical, so publishing would only fire a
        // spurious PropertyNotify without any observable change: skip the write.
        const membership_changes = if (add) !has_atom else has_atom;
        if (!membership_changes) return;

        if (add) {
            if (count >= state_atoms.len) {
                // The preserved set already filled our buffering capacity; the
                // add would at best silently no-op (dropping the new atom), at
                // worst overwrite a slot we dropped. Don't write.
                log.warn("_NET_WM_STATE on 0x{x} holds {d} atoms; cannot add without corrupting the list", .{ win, max_ewmh_states });
                return;
            }
            state_atoms[count] = atom;
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
    .configure = XcbSink.configureShim,
    .border_pixel = XcbSink.borderPixelShim,
    .park = XcbSink.parkShim,
    .stack_only = XcbSink.stackOnlyShim,
    .set_state_atom = XcbSink.setStateAtomShim,
    .flush = XcbSink.flushShim,
    .grab_server = XcbSink.grabShim,
    .ungrab_and_flush = XcbSink.ungrabAndFlushShim,
};

inline fn stackMode(s: Stack) u32 {
    return switch (s) {
        .above => xcb.XCB_STACK_MODE_ABOVE,
    };
}
