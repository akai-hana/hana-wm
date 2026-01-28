//! Simplified batch system with border width support

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");

const XcbOp = union(enum) {
    map: u32,
    unmap: u32,
    configure: struct { win: u32, rect: utils.Rect },
    set_border: struct { win: u32, color: u32 },
    set_border_width: struct { win: u32, width: u16 },
    set_focus: u32,
    raise: u32,
};

const MAX_BATCH_OPS = 256;

pub const Batch = struct {
    wm: *WM,
    ops: [MAX_BATCH_OPS]XcbOp,
    count: usize,

    pub fn begin(wm: *WM) !Batch {
        return .{
            .wm = wm,
            .ops = undefined,
            .count = 0,
        };
    }

    pub fn deinit(_: *Batch) void {}

    pub fn map(self: *Batch, win: u32) !void {
        if (self.count >= MAX_BATCH_OPS) return error.BatchFull;
        self.ops[self.count] = .{ .map = win };
        self.count += 1;
    }

    pub fn unmap(self: *Batch, win: u32) !void {
        if (self.count >= MAX_BATCH_OPS) return error.BatchFull;
        self.ops[self.count] = .{ .unmap = win };
        self.count += 1;
    }

    pub fn configure(self: *Batch, win: u32, rect: utils.Rect) !void {
        if (self.count >= MAX_BATCH_OPS) return error.BatchFull;
        self.ops[self.count] = .{ .configure = .{ .win = win, .rect = rect } };
        self.count += 1;
    }

    pub fn setBorder(self: *Batch, win: u32, color: u32) !void {
        if (self.count >= MAX_BATCH_OPS) return error.BatchFull;
        self.ops[self.count] = .{ .set_border = .{ .win = win, .color = color } };
        self.count += 1;
    }

    pub fn setBorderWidth(self: *Batch, win: u32, width: u16) !void {
        if (self.count >= MAX_BATCH_OPS) return error.BatchFull;
        self.ops[self.count] = .{ .set_border_width = .{ .win = win, .width = width } };
        self.count += 1;
    }

    pub fn setFocus(self: *Batch, win: u32) !void {
        if (self.count >= MAX_BATCH_OPS) return error.BatchFull;
        self.ops[self.count] = .{ .set_focus = win };
        self.count += 1;
    }

    pub fn raise(self: *Batch, win: u32) !void {
        if (self.count >= MAX_BATCH_OPS) return error.BatchFull;
        self.ops[self.count] = .{ .raise = win };
        self.count += 1;
    }

    pub fn execute(self: *Batch) void {
        self.executeNoFlush();
        _ = xcb.xcb_flush(self.wm.conn);
    }

    pub fn executeNoFlush(self: *Batch) void {
        const conn = self.wm.conn;

        for (self.ops[0..self.count]) |op| {
            switch (op) {
                .map => |win| _ = xcb.xcb_map_window(conn, win),
                .unmap => |win| _ = xcb.xcb_unmap_window(conn, win),
                .configure => |cfg| {
                    const r = cfg.rect.clamp();
                    const values = [_]u32{
                        @bitCast(@as(i32, r.x)),
                        @bitCast(@as(i32, r.y)),
                        r.width,
                        r.height,
                    };
                    _ = xcb.xcb_configure_window(conn, cfg.win,
                        xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
                            xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT,
                        &values);
                },
                .set_border => |sb| _ = xcb.xcb_change_window_attributes(conn, sb.win, xcb.XCB_CW_BORDER_PIXEL, &[_]u32{sb.color}),
                .set_border_width => |sbw| _ = xcb.xcb_configure_window(conn, sbw.win, xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{sbw.width}),
                .set_focus => |win| _ = xcb.xcb_set_input_focus(conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, win, xcb.XCB_CURRENT_TIME),
                .raise => |win| _ = xcb.xcb_configure_window(conn, win, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE}),
            }
        }
    }
};
