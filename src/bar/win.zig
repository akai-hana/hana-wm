//! Bar self-window lifecycle (D2 decomposition of bar.zig).
//!
//! Owns the bar's X11 window as a CLIENT: creation, dock/EWMH properties,
//! atom resolution, visual/colormap selection, and the draw-context wiring.
//! This is protocol-side traffic that answers the COMPOSITOR/EWMH contract
//! (dock strut, window type, state hints), not layout policy: hence it
//! lives outside sync, same rationale as the rest of bar's allowlisted
//! self-window traffic in dev/scripts/check-layers.sh.
//!
//! No behavior changes vs the pre-split code; functions moved verbatim with
//! atom storage re-homed from bar's `gBar.atoms` to this module's `atoms`.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const utils = @import("utils");

const types = @import("types");
const drawing = @import("drawing");

/// All atoms needed to declare the bar window as a dock to the compositor.
pub const BarAtoms = struct {
    strut_partial: xcb.xcb_atom_t = 0,
    window_type: xcb.xcb_atom_t = 0,
    window_type_dock: xcb.xcb_atom_t = 0,
    wm_state: xcb.xcb_atom_t = 0,
    state_above: xcb.xcb_atom_t = 0,
    state_sticky: xcb.xcb_atom_t = 0,
    allowed_actions: xcb.xcb_atom_t = 0,
    action_close: xcb.xcb_atom_t = 0,
    action_above: xcb.xcb_atom_t = 0,
    action_stick: xcb.xcb_atom_t = 0,
};

/// Module-level atom storage (was gBar.atoms). Resolved once in initAtoms().
pub var atoms: BarAtoms = .{};

pub fn initAtoms() void {
    const entries = .{
        .{ "strut_partial", "_NET_WM_STRUT_PARTIAL" },
        .{ "window_type", "_NET_WM_WINDOW_TYPE" },
        .{ "window_type_dock", "_NET_WM_WINDOW_TYPE_DOCK" },
        .{ "wm_state", "_NET_WM_STATE" },
        .{ "state_above", "_NET_WM_STATE_ABOVE" },
        .{ "state_sticky", "_NET_WM_STATE_STICKY" },
        .{ "allowed_actions", "_NET_WM_ALLOWED_ACTIONS" },
        .{ "action_close", "_NET_WM_ACTION_CLOSE" },
        .{ "action_above", "_NET_WM_ACTION_ABOVE" },
        .{ "action_stick", "_NET_WM_ACTION_STICK" },
    };
    inline for (entries) |e|
        @field(atoms, e[0]) = utils.getAtomCached(e[1]) catch 0;
}

pub fn calcBarYPos(height: u16) i16 {
    const cs = core.getState();
    return if (cs.config.bar.bar_position == .bottom)
        @intCast(@as(i32, cs.screen.height_in_pixels) - height)
    else
        0;
}

pub const BarWindowSetup = struct { win_id: u32, visual_id: u32, has_argb: bool, colormap: u32 };

/// Set an EWMH atom property on the bar window.
fn setAtomProperty(conn: core.Connection, win_id: u32, prop: u32, atom_type: u32, values: anytype) void {
    _ = xcb.xcb_change_property(conn, xcb.XCB_PROP_MODE_REPLACE, win_id, prop, atom_type, 32, @intCast(values.len), values.ptr);
}

pub fn setWindowProperties(win_id: u32, height: u16) void {
    const cs = core.getState();
    // _NET_WM_STRUT_PARTIAL layout: index 2 = top strut, index 3 = bottom strut.
    const strut: [12]u32 = if (cs.config.bar.bar_position == .top)
        .{ 0, 0, height, 0, 0, 0, 0, 0, 0, cs.screen.width_in_pixels, 0, 0 }
    else
        .{ 0, 0, 0, height, 0, 0, 0, 0, 0, 0, 0, cs.screen.width_in_pixels };
    const entries = .{
        .{ "strut_partial", xcb.XCB_ATOM_CARDINAL, &strut },
        .{ "window_type", xcb.XCB_ATOM_ATOM, &[_]u32{atoms.window_type_dock} },
        .{ "wm_state", xcb.XCB_ATOM_ATOM, &[_]u32{ atoms.state_above, atoms.state_sticky } },
        .{ "allowed_actions", xcb.XCB_ATOM_ATOM, &[_]u32{ atoms.action_close, atoms.action_above, atoms.action_stick } },
    };
    inline for (entries) |e| {
        const atom = @field(atoms, e[0]);
        if (atom != 0) setAtomProperty(cs.conn, win_id, atom, e[1], e[2]);
    }
}

pub fn destroyBarWindow(conn: core.Connection, win_id: u32, colormap: u32) void {
    _ = xcb.xcb_destroy_window(conn, win_id);
    if (colormap != 0) _ = xcb.xcb_free_colormap(conn, colormap);
}

pub fn createBarWindow(height: u16, y_pos: i16) BarWindowSetup {
    const cs = core.getState();
    const want_transparency = cs.config.bar.getAlpha16() < 0xFFFF;
    const visual_id = if (want_transparency)
        drawing.findVisualByDepth(cs.screen, 32)
    else
        cs.screen.root_visual;
    const depth: u8 = if (want_transparency) 32 else xcb.XCB_COPY_FROM_PARENT;
    const colormap: u32 = if (want_transparency) blk: {
        const cmap = xcb.xcb_generate_id(cs.conn);
        _ = xcb.xcb_create_colormap(cs.conn, xcb.XCB_COLORMAP_ALLOC_NONE, cmap, cs.screen.root, visual_id);
        break :blk cmap;
    } else 0;
    const win_id = xcb.xcb_generate_id(cs.conn);
    const value_mask = xcb.XCB_CW_BACK_PIXEL | xcb.XCB_CW_BORDER_PIXEL |
        xcb.XCB_CW_OVERRIDE_REDIRECT | xcb.XCB_CW_EVENT_MASK |
        if (want_transparency) xcb.XCB_CW_COLORMAP else 0;
    const base_events = xcb.XCB_EVENT_MASK_EXPOSURE | xcb.XCB_EVENT_MASK_BUTTON_PRESS;
    // Positional slots, in the same order as the CW_* bits above:
    // [0]=BACK_PIXEL, [1]=BORDER_PIXEL, [2]=OVERRIDE_REDIRECT,
    // [3]=EVENT_MASK, [4]=COLORMAP.
    const value_list = [5]u32{ 0, 0, 1, base_events, colormap };
    _ = xcb.xcb_create_window(cs.conn, depth, win_id, cs.screen.root, 0, y_pos, cs.screen.width_in_pixels, height, 0, xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT, visual_id, @intCast(value_mask), &value_list);
    return .{ .win_id = win_id, .visual_id = visual_id, .has_argb = want_transparency, .colormap = colormap };
}

pub fn createDrawContext(setup: BarWindowSetup, height: u16) !*drawing.DrawContext {
    const cs = core.getState();
    const dc = try drawing.DrawContext.initWithVisual(
        cs.alloc,
        cs.conn,
        setup.win_id,
        cs.screen.width_in_pixels,
        height,
        setup.visual_id,
        core.dpi_info.load(.acquire),
        setup.has_argb,
        cs.config.bar.transparency,
    );
    errdefer dc.deinit();
    try drawing.loadBarFonts(dc, null);
    return dc;
}
