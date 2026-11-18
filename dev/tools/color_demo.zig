//! Live color-compositing lab.
//!
//! Opens one override-redirect ARGB window and paints swatches whose stored
//! premultiplied RGB (`S`) follows different formulas for the same alpha
//! column (`A`). A compositor blends each pixel as:
//!
//!     out = clamp(S + (1 - A) * background)
//!
//! so the formulas differ only in how much of the base color is contributed.
//! Run with `zig build color-demo`; click the window (or press a key) to close.

const std = @import("std");
const core = @import("core");
const drawing = @import("drawing");
const surface = @import("surface");
const types = @import("types");

const xcb = core.xcb;

const window_title = "hana color compositing lab";
const font_size: u16 = 12;
const title_size: u16 = 16;
var base_colors = [_]u32{ 0xac3232, 0x3298ac };
var base_names = [_][]const u8{ "#AC3232", "#3298AC" };
const alphas = [_]u8{ 0, 32, 64, 128, 192, 255 };

const Mode = union(enum) {
    color: surface.ColorMode,
    solid,
};

const Row = struct {
    label: []const u8,
    mode: Mode,
    /// Name written to `surface.color_mode_path` when this row is clicked.
    id: []const u8,
};

const rows = [_]Row{
    .{ .label = "normal     S = A*C", .mode = .{ .color = .normal }, .id = "normal" },
    .{ .label = "legacy     S = C", .mode = .{ .color = .legacy }, .id = "legacy" },
    .{ .label = "linear     S = encode(A*decode(C))", .mode = .{ .color = .linear }, .id = "linear" },
    .{ .label = "screen     k = 1-(1-A)^2", .mode = .{ .color = .screen }, .id = "screen" },
    .{ .label = "smoothstep k = A^2(3-2A)", .mode = .{ .color = .smoothstep }, .id = "smoothstep" },
    .{ .label = "sine       k = sin(pi*A/2)", .mode = .{ .color = .sine }, .id = "sine" },
    .{ .label = "floor .25  k = max(A,.25)", .mode = .{ .color = .floor25 }, .id = "floor25" },
    .{ .label = "boost .25  k = min(1,A+.25)", .mode = .{ .color = .boost25 }, .id = "boost25" },
    .{ .label = "posterize  k = round(4A)/4", .mode = .{ .color = .posterize4 }, .id = "posterize4" },
    .{ .label = "opaque     A=255, S=C (reference)", .mode = .solid, .id = "" },
};

const Layout = struct {
    width: u16,
    height: u16,
    label_w: u16,
    swatch_w: u16,
    swatch_h: u16,
    row_h: u16,
    rows_y: u16,
    group_gap: u16,
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;

    var arg_it = std.process.Args.Iterator.init(init.minimal.args);
    _ = arg_it.skip();
    var arg_index: usize = 0;
    while (arg_it.next()) |arg| {
        if (arg_index >= base_colors.len) break;
        const rgb = parseHexColor(arg) orelse {
            std.debug.print("color-demo: ignoring non-#RRGGBB argument '{s}'\n", .{arg});
            continue;
        };
        base_colors[arg_index] = rgb;
        base_names[arg_index] = arg;
        arg_index += 1;
    }

    const conn = xcb.xcb_connect(null, null) orelse return error.X11ConnectionFailed;
    defer xcb.xcb_disconnect(conn);
    if (xcb.xcb_connection_has_error(conn) != 0) return error.X11ConnectionFailed;

    const setup = xcb.xcb_get_setup(conn);
    const screen_iter = xcb.xcb_setup_roots_iterator(setup);
    const screen = screen_iter.data orelse return error.NoScreen;

    const visual = surface.findVisualByDepth(screen, 32) orelse {
        std.debug.print("color-demo: no depth-32 visual on this screen; an ARGB compositor is required\n", .{});
        return error.NoArgbVisual;
    };

    const layout = makeLayout(screen);
    const created = try createWindow(conn, screen, visual, layout);
    defer {
        _ = xcb.xcb_destroy_window(conn, created.window);
        _ = xcb.xcb_free_colormap(conn, created.colormap);
        _ = xcb.xcb_flush(conn);
    }

    const dc = try drawing.DrawContext.initWithVisual(
        allocator,
        conn,
        created.window,
        layout.width,
        layout.height,
        visual,
        96.0,
        true,
        1.0,
    );
    defer dc.deinit();
    try drawing.loadBarFonts(dc, allocator, &.{"monospace"}, font_size);

    std.debug.print(
        "color-demo: {s} {d}x{d}; compositor {s}; left-click a row to apply to the bar, right-click to close\n",
        .{
            if (dc.surface.composited) "composited" else "NOT composited",
            layout.width,
            layout.height,
            if (dc.surface.composited) "active" else "inactive (alpha will not blend)",
        },
    );

    _ = xcb.xcb_map_window(conn, created.window);
    _ = xcb.xcb_configure_window(
        conn,
        created.window,
        xcb.XCB_CONFIG_WINDOW_STACK_MODE,
        &[_]u32{xcb.XCB_STACK_MODE_ABOVE},
    );
    _ = xcb.xcb_flush(conn);

    var redraw = true;
    var selected: []const u8 = "";
    while (true) {
        if (redraw) {
            paint(dc, layout, selected);
            redraw = false;
        }
        const ev = xcb.xcb_wait_for_event(conn) orelse break;
        defer std.c.free(ev);
        switch (ev.*.response_type & 0x7f) {
            xcb.XCB_EXPOSE => redraw = true,
            xcb.XCB_BUTTON_PRESS => {
                const b: *const xcb.xcb_button_press_event_t = @ptrCast(@alignCast(ev));
                // Right button closes; the terminal's Ctrl+C always works too.
                if (b.detail == 3) break;
                if (b.event_y < 0) continue;
                const y: u16 = @intCast(b.event_y);
                if (y < 106) {
                    // Header = back to hana's normal fill behavior.
                    selected = "native";
                    applyMode(init.io, conn, screen, selected);
                } else if (y >= layout.rows_y) {
                    const rel = y - layout.rows_y;
                    const idx = rel / layout.row_h;
                    if (idx < rows.len and rows[idx].id.len != 0) {
                        selected = rows[idx].id;
                        applyMode(init.io, conn, screen, selected);
                    }
                }
                redraw = true;
            },
            xcb.XCB_KEY_PRESS => break,
            xcb.XCB_DESTROY_NOTIFY => break,
            else => {},
        }
    }
}

/// Writes the selected formula and pokes hana's bar with a synthetic Expose,
/// which makes handleExpose re-read the file and repaint the whole bar.
fn applyMode(io: std.Io, conn: core.Connection, screen: *xcb.xcb_screen_t, id: []const u8) void {
    var f = std.Io.Dir.createFileAbsolute(io, surface.color_mode_path, .{}) catch |err| {
        std.debug.print("color-demo: cannot write {s}: {s}\n", .{ surface.color_mode_path, @errorName(err) });
        return;
    };
    f.writeStreamingAll(io, id) catch {};
    f.close(io);

    const bar = findDockWindow(conn, screen.root) orelse {
        std.debug.print("color-demo: applied {s}, but no dock window found to repaint\n", .{id});
        return;
    };
    var event = std.mem.zeroes(xcb.xcb_expose_event_t);
    event.response_type = xcb.XCB_EXPOSE;
    event.window = bar;
    _ = xcb.xcb_send_event(conn, 0, bar, xcb.XCB_EVENT_MASK_NO_EVENT, @ptrCast(&event));
    _ = xcb.xcb_flush(conn);
    std.debug.print("color-demo: applied {s}\n", .{id});
}

fn findDockWindow(conn: core.Connection, root: u32) ?u32 {
    const type_atom = internAtom(conn, "_NET_WM_WINDOW_TYPE") orelse return null;
    const dock_atom = internAtom(conn, "_NET_WM_WINDOW_TYPE_DOCK") orelse return null;
    const tree = xcb.xcb_query_tree_reply(conn, xcb.xcb_query_tree(conn, root), null) orelse return null;
    defer std.c.free(tree);
    const children = xcb.xcb_query_tree_children(tree);
    const count: usize = @intCast(xcb.xcb_query_tree_children_length(tree));
    for (0..count) |i| {
        const win = children[i];
        const reply = xcb.xcb_get_property_reply(
            conn,
            xcb.xcb_get_property(conn, 0, win, type_atom, xcb.XCB_ATOM_ATOM, 0, 8),
            null,
        ) orelse continue;
        defer std.c.free(reply);
        if (reply.*.format != 32 or reply.*.value_len == 0) continue;
        const values: [*]const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(reply)));
        for (0..reply.*.value_len) |j| {
            if (values[j] == dock_atom) return win;
        }
    }
    return null;
}

fn internAtom(conn: core.Connection, name: []const u8) ?u32 {
    const reply = xcb.xcb_intern_atom_reply(
        conn,
        xcb.xcb_intern_atom(conn, 0, @intCast(name.len), name.ptr),
        null,
    ) orelse return null;
    defer std.c.free(reply);
    return reply.*.atom;
}

fn parseHexColor(text: []const u8) ?u32 {
    const digits = if (text.len != 0 and text[0] == '#') text[1..] else text;
    if (digits.len != 6) return null;
    return std.fmt.parseInt(u32, digits, 16) catch null;
}

fn makeLayout(screen: *xcb.xcb_screen_t) Layout {
    const margin: u16 = 14;
    const row_h: u16 = 49;
    const rows_y: u16 = 112;
    const want_w: u32 = 1480;
    const want_h: u32 = @as(u32, rows_y) + @as(u32, rows.len) * row_h + 14;
    const width: u16 = @intCast(@min(want_w, @as(u32, screen.width_in_pixels) - 32));
    const height: u16 = @intCast(@min(want_h, @as(u32, screen.height_in_pixels) - 48));
    const label_w: u16 = @intCast(@min(@as(u32, 310), @as(u32, width) / 3));
    const group_gap: u16 = 26;
    const cols: u32 = alphas.len;
    const groups: u32 = base_colors.len;
    const horizontal: u32 = @as(u32, width) - 2 * margin - label_w - group_gap * (groups - 1);
    const swatch_w: u16 = @intCast(@max(@as(u32, 40), horizontal / (cols * groups)));
    const swatch_h: u16 = 34;
    return .{
        .width = width,
        .height = height,
        .label_w = label_w,
        .swatch_w = swatch_w,
        .swatch_h = swatch_h,
        .row_h = row_h,
        .rows_y = rows_y,
        .group_gap = group_gap,
    };
}

const CreatedWindow = struct { window: u32, colormap: u32 };

fn createWindow(conn: core.Connection, screen: *xcb.xcb_screen_t, visual: u32, layout: Layout) !CreatedWindow {
    const win = xcb.xcb_generate_id(conn);
    const colormap = xcb.xcb_generate_id(conn);
    _ = xcb.xcb_create_colormap(
        conn,
        xcb.XCB_COLORMAP_ALLOC_NONE,
        colormap,
        screen.root,
        visual,
    );

    const x: i16 = @intCast(@max(0, @divTrunc(@as(i32, screen.width_in_pixels) - layout.width, 2)));
    const y: i16 = @intCast(@max(0, @divTrunc(@as(i32, screen.height_in_pixels) - layout.height, 2)));
    const events = xcb.XCB_EVENT_MASK_EXPOSURE |
        xcb.XCB_EVENT_MASK_BUTTON_PRESS |
        xcb.XCB_EVENT_MASK_KEY_PRESS |
        xcb.XCB_EVENT_MASK_STRUCTURE_NOTIFY;
    const mask = xcb.XCB_CW_BACK_PIXEL |
        xcb.XCB_CW_BORDER_PIXEL |
        xcb.XCB_CW_OVERRIDE_REDIRECT |
        xcb.XCB_CW_EVENT_MASK |
        xcb.XCB_CW_COLORMAP;
    const values = [5]u32{ 0, 0, 1, events, colormap };
    _ = xcb.xcb_create_window(
        conn,
        32,
        win,
        screen.root,
        x,
        y,
        layout.width,
        layout.height,
        0,
        xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT,
        visual,
        mask,
        &values,
    );
    _ = xcb.xcb_change_property(
        conn,
        xcb.XCB_PROP_MODE_REPLACE,
        win,
        xcb.XCB_ATOM_WM_NAME,
        xcb.XCB_ATOM_STRING,
        8,
        window_title.len,
        window_title.ptr,
    );
    return .{ .window = win, .colormap = colormap };
}

fn paint(dc: *drawing.DrawContext, layout: Layout, selected: []const u8) void {
    const s = &dc.surface;
    var last_pixel: ?u32 = null;

    rawFill(s, &last_pixel, 0, 0, layout.width, layout.height, 0);
    rawFill(s, &last_pixel, 6, 6, layout.width - 12, 100, 0xff10_1014);

    const text_color = types.Color.rgba(0xffff_ffff);
    const dim_color = types.Color.rgba(0xffb8_b8c0);
    const accent = types.Color.rgba(0xffff_c040);

    dc.drawTextSized(14, 12, "hana color compositing lab", title_size, text_color) catch {};
    dc.drawTextSized(
        14,
        36,
        "out = clamp(S + (1-A)*B)   A = alpha byte 0..255   S = stored premultiplied RGB",
        font_size,
        dim_color,
    ) catch {};
    const comp = if (s.composited)
        "compositor ACTIVE - swatches blend over the live desktop"
    else
        "NO COMPOSITOR - the server ignores alpha; formulas below will not blend";
    dc.drawTextSized(14, 54, comp, font_size, if (s.composited) accent else text_color) catch {};
    dc.drawTextSized(14, 74, "left-click a row = apply to bar   header = native   right-click = close", font_size, dim_color) catch {};

    const group_w: u16 = layout.swatch_w * @as(u16, @intCast(alphas.len));
    const group1_x: u16 = 14 + layout.label_w;
    const group2_x: u16 = group1_x + group_w + layout.group_gap;

    for (base_names, 0..) |name, i| {
        const gx: u16 = if (i == 0) group1_x else group2_x;
        dc.drawTextSized(gx, 86, name, font_size, text_color) catch {};
    }
    for (alphas, 0..) |a, col| {
        var buf: [16]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "{d}", .{a}) catch continue;
        const gx1 = group1_x + layout.swatch_w * @as(u16, @intCast(col));
        const gx2 = group2_x + layout.swatch_w * @as(u16, @intCast(col));
        dc.drawTextSized(gx1 + 4, 86, label, font_size, dim_color) catch {};
        dc.drawTextSized(gx2 + 4, 86, label, font_size, dim_color) catch {};
    }

    for (rows, 0..) |row, r| {
        const y: u16 = layout.rows_y + layout.row_h * @as(u16, @intCast(r));
        rawFill(s, &last_pixel, 6, y, 8 + layout.label_w - 14, layout.row_h - 6, 0xff10_1014);
        const row_color = if (std.mem.eql(u8, row.id, selected)) accent else text_color;
        dc.drawTextSized(14, y + 8, row.label, font_size, row_color) catch {};

        for (base_colors, 0..) |color, group| {
            const gx: u16 = if (group == 0) group1_x else group2_x;
            for (alphas, 0..) |a, col| {
                const x = gx + layout.swatch_w * @as(u16, @intCast(col));
                const sx = x + 4;
                const sw = layout.swatch_w - 8;
                const sy = y + 7;
                rawFill(s, &last_pixel, sx, sy, sw, layout.swatch_h, surface.premultiply(0xffff_ffff, 0x28));
                const pixel = formulaPixel(row.mode, color, a);
                rawFill(s, &last_pixel, sx + 1, sy + 1, sw - 2, layout.swatch_h - 2, pixel);
            }
        }
    }

    s.blitImpl(0, layout.width, true);
}

fn formulaPixel(mode: Mode, rgb: u32, alpha: u8) u32 {
    return switch (mode) {
        .color => |m| surface.packFillMode(types.Color.legacy(rgb), alpha, true, true, m),
        .solid => 0xff00_0000 | rgb,
    };
}

fn rawFill(
    s: *surface.Surface,
    last_pixel: *?u32,
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    pixel: u32,
) void {
    if (width == 0 or height == 0) return;
    if (last_pixel.* == null or last_pixel.*.? != pixel) {
        _ = xcb.xcb_change_gc(s.conn, s.gc, xcb.XCB_GC_FOREGROUND, &[_]u32{pixel});
        last_pixel.* = pixel;
    }
    const rect = xcb.xcb_rectangle_t{
        .x = @intCast(x),
        .y = @intCast(y),
        .width = width,
        .height = height,
    };
    _ = xcb.xcb_poly_fill_rectangle(s.conn, s.pixmap, s.gc, 1, &rect);
}
