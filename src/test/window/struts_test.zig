//! Inbound strut handling (F-80): foreign docks claim screen edges.
//!
//! Two halves in one file: the PURE parse (a `_NET_WM_STRUT_PARTIAL` payload
//! is 12 CARDINALs, only the first four matter under D27) runs headlessly;
//! the admission/property-notify/unmanage lifecycle needs the display fixture.
//!
//! WHAT IS PINNED
//!   A DOCK-typed window floats at its own geometry (never a tiled slot) and
//!   its strut shrinks `usable_area.workArea` before the admitting reconcile;
//!   a strut rewrite re-publishes through the coalesced PropertyNotify dirty
//!   set (no per-event round trip, one re-tile per batch); unmap releases the
//!   claim. A non-dock's identical property is ignored -- the window id is
//!   client-controlled, and the right to shrink everyone's work area is not
//!   granted to every client.

const std = @import("std");
const testing = std.testing;
const core = @import("core");
const xcb = core.xcb;
const model = @import("model");
const pipeline = @import("pipeline");
const window = @import("window");
const atoms = @import("atoms");
const struts = @import("struts");
const usable_area = @import("usable_area");
const fixture = @import("fixture");

test "struts: parse reads the four edge widths and ignores the partial ranges" {
    // EWMH layout: left, right, top, bottom, then the eight per-monitor range
    // bounds (start/end along each edge) -- the ranges are a D27-exempt
    // refinement, so the payload's tail must not leak into the insets.
    const data = [_]u32{
        10, 20, 30, 40, // edges
        1, 2, 3, 4, 5, 6, 7, 8, // ranges: ignored
    };
    const insets = struts.parsePartial(&data).?;
    try testing.expectEqual(@as(u16, 10), insets.left);
    try testing.expectEqual(@as(u16, 20), insets.right);
    try testing.expectEqual(@as(u16, 30), insets.top);
    try testing.expectEqual(@as(u16, 40), insets.bottom);
}

test "struts: a payload that is not the EWMH layout is dropped, never guessed" {
    // format=32 lets a client send any length; a 4-value list looks like the
    // old _NET_WM_STRUT shape, and guessing the rest would invent insets the
    // client never declared.
    const short = [_]u32{ 1, 2, 3, 4 };
    try testing.expect(struts.parsePartial(&short) == null);
    const empty = [_]u32{};
    try testing.expect(struts.parsePartial(&empty) == null);
}

fn setAtomsProp(conn: core.Connection, win: u32, comptime name: []const u8, list: []const u32) void {
    const atom = atoms.getAtomOrZero(name);
    if (atom == 0) return;
    _ = xcb.xcb_change_property(conn, xcb.XCB_PROP_MODE_REPLACE, win, atom, xcb.XCB_ATOM_ATOM, 32, @intCast(list.len), list.ptr);
}

fn setCardinalProp(conn: core.Connection, win: u32, comptime name: []const u8, list: []const u32) void {
    const atom = atoms.getAtomOrZero(name);
    if (atom == 0) return;
    _ = xcb.xcb_change_property(conn, xcb.XCB_PROP_MODE_REPLACE, win, atom, xcb.XCB_ATOM_CARDINAL, 32, @intCast(list.len), list.ptr);
}

fn strut12(top: u32) [12]u32 {
    const w: u32 = core.getState().screen.width_in_pixels;
    return .{ 0, 0, top, 0, 0, 0, 0, 0, 0, w, 0, 0 };
}

fn declareDock(fx: *const fixture.Fx, win: u32, top: u32) void {
    const dock_atom = atoms.getAtomOrZero("_NET_WM_WINDOW_TYPE_DOCK");
    setAtomsProp(fx.conn, win, "_NET_WM_WINDOW_TYPE", &[_]u32{dock_atom});
    setCardinalProp(fx.conn, win, "_NET_WM_STRUT_PARTIAL", &strut12(top));
    fx.flush();
}

fn admitViaMapRequest(win: u32) void {
    var ev: xcb.xcb_map_request_event_t = std.mem.zeroes(xcb.xcb_map_request_event_t);
    ev.response_type = xcb.XCB_MAP_REQUEST;
    ev.window = win;
    window.handleMapRequest(&ev);
}

test "struts: admitting a DOCK window floats it and shrinks the work area" {
    var fx = try fixture.setUp("struts_test");
    defer fx.deinit();
    const m = pipeline.state();

    const dock = fx.createWindow();
    defer _ = usable_area.releaseDockClaim(dock); // idempotent if the test already released
    declareDock(fx, dock, 30);
    admitViaMapRequest(dock);
    fx.flush();

    // A dock sits at its self-chosen geometry, never a tiled slot.
    const e = m.store.get(dock) orelse return error.ExpectedManaged;
    try testing.expect(e.anchor == .floating);
    // The strut landed in the ledger BEFORE the admitting reconcile.
    try testing.expectEqual(@as(i16, 30), usable_area.workArea(core.getState().screen).y);
    const c = usable_area.dockClaimOf(dock) orelse return error.ExpectedClaim;
    try testing.expectEqual(@as(u16, 30), c.top);

    // Unmap: the claim releases with the window; unmanage's re-tile restores
    // the full area.
    _ = xcb.xcb_unmap_window(fx.conn, dock);
    fx.flush();
    var uev: xcb.xcb_unmap_notify_event_t = std.mem.zeroes(xcb.xcb_unmap_notify_event_t);
    uev.response_type = xcb.XCB_UNMAP_NOTIFY;
    uev.window = dock;
    window.handleUnmapNotify(&uev);
    fx.flush();
    try testing.expect(usable_area.dockClaimOf(dock) == null);
    try testing.expectEqual(@as(i16, 0), usable_area.workArea(core.getState().screen).y);
}

test "struts: a strut rewrite re-publishes through the coalesced dirty set" {
    var fx = try fixture.setUp("struts_test");
    defer fx.deinit();
    const conn = fx.conn;

    const dock = fx.createWindow();
    declareDock(fx, dock, 30);
    admitViaMapRequest(dock);
    fx.flush();
    try testing.expectEqual(@as(i16, 30), usable_area.workArea(core.getState().screen).y);

    // Rewrite the strut, then deliver ONLY the PropertyNotify: the refresh
    // must mark (no immediate round trip), the batch flush must re-read once,
    // and the new inset must be live after the flush's single re-tile.
    setCardinalProp(conn, dock, "_NET_WM_STRUT_PARTIAL", &strut12(60));
    fx.flush();
    var pev: xcb.xcb_property_notify_event_t = std.mem.zeroes(xcb.xcb_property_notify_event_t);
    pev.response_type = xcb.XCB_PROPERTY_NOTIFY;
    pev.window = dock;
    pev.atom = atoms.getAtomOrZero("_NET_WM_STRUT_PARTIAL");
    window.handlePropertyNotify(&pev);
    try testing.expectEqual(@as(usize, 1), window.pendingPropertyRefreshCount());
    try testing.expectEqual(@as(i16, 30), usable_area.workArea(core.getState().screen).y);

    window.flushPropertyRefresh();
    try testing.expectEqual(@as(usize, 0), window.pendingPropertyRefreshCount());
    try testing.expectEqual(@as(i16, 60), usable_area.workArea(core.getState().screen).y);

    _ = xcb.xcb_unmap_window(conn, dock);
    fx.flush();
    var uev: xcb.xcb_unmap_notify_event_t = std.mem.zeroes(xcb.xcb_unmap_notify_event_t);
    uev.response_type = xcb.XCB_UNMAP_NOTIFY;
    uev.window = dock;
    window.handleUnmapNotify(&uev);
    fx.flush();
    try testing.expect(usable_area.dockClaimOf(dock) == null);
    try testing.expectEqual(@as(i16, 0), usable_area.workArea(core.getState().screen).y);
}

test "struts: a non-dock window's identical strut property is ignored" {
    var fx = try fixture.setUp("struts_test");
    defer fx.deinit();
    const m = pipeline.state();

    const win = fx.createWindow();
    setCardinalProp(fx.conn, win, "_NET_WM_STRUT_PARTIAL", &strut12(30));
    fx.flush();
    admitViaMapRequest(win); // admitted through the same production entry
    fx.flush();

    // No DOCK type: managed as a plain window, no claim published.
    const e = m.store.get(win) orelse return error.ExpectedManaged;
    try testing.expect(e.anchor != .floating);
    try testing.expect(usable_area.dockClaimOf(win) == null);
    try testing.expectEqual(@as(i16, 0), usable_area.workArea(core.getState().screen).y);
}
