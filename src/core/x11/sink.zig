//! The send seam: the interface every optional subsystem emits requests
//! through, and its one production implementation.
//!
//! `Sink` (the vtable) lives HERE, beside its shims, rather than in the
//! reconciler that consumes it: this low-level implementation must not import
//! the high-level planner just to name the type it implements. Requests are
//! planned in `reconcile.zig` and dispatched by these shims -- the sanctioned
//! seam where raw XCB calls are allowed. Each shim wraps the exact request
//! pattern it consolidates:
//!   map          ~ xcb_map_window (fresh window before its park)
//!   configure    ~ one xcb_configure_window; mask from the Configure fields,
//!                  stack mode merged in when it changed
//!   borderPixel  ~ requests.setBorderPixel
//!   park         ~ X-offscreen + BELOW merged into one request
//!   stackOnly    ~ requests.raiseWindow (ABOVE; the only stack mode)
//!   setStateAtom ~ read-merge-write of one _NET_WM_STATE atom list
//!   flush/grab   ~ conn.flush / requests.grabServer / ungrabAndFlush

const std = @import("std");
const core = @import("core");
const xcb = core.xcb;
// Offscreen positioning: windows on inactive workspaces are parked here so
// they are hidden WITHOUT being unmapped (unmapping causes some apps to pause).
//
// X11's ConfigureWindow encodes x/y as INT16, so -32768 is the hard floor.
// -4000 would only clear a single 3840px display; -30000 clears any realistic
// combined desktop with floor headroom.
pub const offscreen_x_position: i32 = -30000;
const log = std.log.scoped(.sink);

const model = @import("model");
const requests = @import("requests");
/// Stacking mode vocabulary; `above` is the only mode the WM emits.
pub const Stack = enum { above };

/// The X11 wire form of one configure: a mask naming the live fields plus a
/// value list. X does NOT index the value list by mask bit -- it consumes slots
/// SEQUENTIALLY, lowest set bit first. Packing at absolute protocol slot
/// indices therefore sends zeros for every partial mask and gets rejected.
const ConfigureWire = struct { mask: u16, values: [6]u32 };

/// Assembles the configure request body (pure, no X connection); values pack
/// in mask-bit order, skipping unset fields (see ConfigureWire).
pub fn configureWire(c: Configure) ConfigureWire {
    var mask: u16 = 0;
    var values = [_]u32{ 0, 0, 0, 0, 0, 0 };
    var n: usize = 0;
    if (c.rect) |r| {
        mask |= xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
            xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT;
        values[n] = model.toXcbCoord(r.x);
        values[n + 1] = model.toXcbCoord(r.y);
        values[n + 2] = r.width;
        values[n + 3] = r.height;
        n += 4;
    } else if (c.size) |d| {
        mask |= xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT;
        values[n] = d.width;
        values[n + 1] = d.height;
        n += 2;
    }
    if (c.bw) |bw| {
        mask |= xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH;
        values[n] = bw;
        n += 1;
    }
    if (c.stack) |s| {
        mask |= xcb.XCB_CONFIG_WINDOW_STACK_MODE;
        values[n] = stackMode(s);
        n += 1;
    }
    return .{ .mask = mask, .values = values };
}

/// Outcome of the `_NET_WM_STATE` read-modify-write decision (see
/// `planStateWrite`): write, or one of the three reasons not to.
pub const StateWrite = enum { write, noop, skip_oversize, skip_capacity };

/// Pure decision for the `_NET_WM_STATE` read-modify-write in
/// setStateAtomShim, pulled out so the guarantees bounding that dispatch-path
/// round trip are testable without a server (sink_test.zig):
///
/// - `noop`: the list would not change -- publishing would only fire a
///   spurious PropertyNotify, so no write.
/// - `skip_oversize`: the list on the wire is longer than the read buffer
///   (`bytes_after != 0`) -- a REPLACE would truncate it, so no write.
/// - `skip_capacity`: the preserved set filled the buffer and the request wants
///   an add -- the new atom cannot be kept, so no write.
/// - `write`: membership changes and the write is safe.
///
/// Order is pinned: oversize wins over everything, then membership.
pub fn planStateWrite(
    bytes_after: u32,
    has_atom: bool,
    add: bool,
    count: usize,
    capacity: usize,
) StateWrite {
    if (bytes_after != 0) return .skip_oversize;
    const membership_changes = if (add) !has_atom else has_atom;
    if (!membership_changes) return .noop;
    if (add and count >= capacity) return .skip_capacity;
    return .write;
}

/// One configure request, described by which parts of the window are changing.
/// A null field means "leave it alone" -- X's own semantics for an unset mask
/// bit, expressed instead of implied by which shim was called.
pub const Configure = struct {
    rect: ?model.Rect = null,
    /// Width/height WITHOUT X/Y: the resize-while-parked shape. A parked
    /// window must re-render at the new workarea size while staying offscreen
    /// (the bar-toggle pre-resize), and a `rect` would move it back over the
    /// live workspace. Mutually exclusive with `rect` on the wire.
    size: ?model.Dims = null,
    bw: ?u16 = null,
    stack: ?Stack = null,
};

/// Request sink: the output port every placement decision writes through.
/// Production wires `XcbSink`; tests wire a recorder, which is the point of the
/// vtable. One batch = everything queued between caller flushes (xcb buffers
/// requests; the CALLER decides when to flush).
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
    /// Describe WHAT changed; the shim decides how many X bits that is. The
    /// signature makes it impossible to ask for geometry and border width as
    /// two separate requests.
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
    /// preserving every other atom in the list -- list editing, nothing
    /// specific to fullscreen.
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
        const ck = xcb.xcb_map_window(XcbSink.fromPtr(ptr).conn, win);
        requests.noteSequence(win, ck.sequence);
    }

    fn configureShim(ptr: *anyopaque, win: u32, c: Configure) void {
        const w = configureWire(c);
        // All-zero mask: a no-op request at best, a protocol error at worst.
        if (w.mask == 0) return;
        const ck = xcb.xcb_configure_window(XcbSink.fromPtr(ptr).conn, win, w.mask, &w.values);
        requests.noteSequence(win, ck.sequence);
    }

    fn borderPixelShim(ptr: *anyopaque, win: u32, pixel: u32) void {
        requests.setBorderPixel(XcbSink.fromPtr(ptr).conn, win, pixel);
    }

    /// Park = offscreen X + stack BELOW in ONE configure_window.
    ///
    /// Deliberately NOT folded into `configure`: park must assert X ONLY.
    /// configure_window leaves unset mask bits alone, so sliding offscreen costs
    /// one coordinate, whereas a `Configure.rect` would also assert Y/WIDTH/
    /// HEIGHT and MOVE/RESIZE the window to whatever the caller believed its
    /// geometry was. The park call site has no trustworthy rect to assert.
    fn parkShim(ptr: *anyopaque, win: u32) void {
        const ck = xcb.xcb_configure_window(
            XcbSink.fromPtr(ptr).conn,
            win,
            xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_STACK_MODE,
            &[_]u32{
                @bitCast(offscreen_x_position),
                xcb.XCB_STACK_MODE_BELOW,
            },
        );
        requests.noteSequence(win, ck.sequence);
    }

    fn stackOnlyShim(ptr: *anyopaque, win: u32, s: Stack) void {
        switch (s) {
            .above => requests.raiseWindow(XcbSink.fromPtr(ptr).conn, win),
        }
    }

    /// Add/remove `atom` in the `_NET_WM_STATE` list on `win` while PRESERVING
    /// the other atoms listed (a REPLACE of just this one would nuke e.g.
    /// _NET_WM_STATE_ABOVE/_STICKY the client set). One blocking
    /// get_property + one replace-mode change_property.
    ///
    /// The read buffer is bounded, so a longer list would be silently
    /// TRUNCATED by the REPLACE; `bytes_after != 0` detects that and we bail.
    const max_ewmh_states = 64;

    /// Set / clear `atom` on `_NET_WM_STATE` for `win`, preserving the rest of
    /// the list. The write/no-write decision is the pure `planStateWrite` above
    /// (pinned in sink_test); this half reads, feeds the plan, publishes.
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
        var bytes_after: u32 = 0;
        const get_cookie = xcb.xcb_get_property(conn, 0, win, state_atom, xcb.XCB_ATOM_ATOM, 0, state_atoms.len);
        if (xcb.xcb_get_property_reply(conn, get_cookie, null)) |reply| {
            defer std.c.free(reply);
            if (reply.*.format == 32 and reply.*.type == xcb.XCB_ATOM_ATOM) {
                bytes_after = reply.*.bytes_after;
                if (bytes_after == 0) {
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
        }

        switch (planStateWrite(bytes_after, has_atom, add, count, state_atoms.len)) {
            .noop => return,
            .skip_oversize => {
                log.warn("_NET_WM_STATE on 0x{x} exceeds {d} atoms; skipping state-atom update", .{ win, max_ewmh_states });
                return;
            },
            .skip_capacity => {
                log.warn("_NET_WM_STATE on 0x{x} holds {d} atoms; cannot add without corrupting the list", .{ win, max_ewmh_states });
                return;
            },
            .write => {},
        }

        if (add) {
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
