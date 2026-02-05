//! Batch XCB operations for better performance

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");
const focus = @import("focus");
const debug = @import("debug");

const XcbOp = union(enum) {
    map: u32,
    unmap: u32,
    configure: struct { win: u32, rect: utils.Rect },
    set_border: struct { win: u32, color: u32 },
    set_border_width: struct { win: u32, width: u16 },
    raise: u32,
};

const MAX_BATCH_OPS = 256;
const AUTO_FLUSH_THRESHOLD = 200;

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

    pub inline fn deinit(_: *Batch) void {
        // No cleanup needed - ops array is stack-allocated
    }

    inline fn pushOp(self: *Batch, op: XcbOp) !void {
        // OPTIMIZATION: Single comparison for common case
        if (self.count < AUTO_FLUSH_THRESHOLD) {
            self.ops[self.count] = op;
            self.count += 1;
            return;
        }
        
        // OPTIMIZATION: Rare path - auto-flush
        if (self.count >= MAX_BATCH_OPS) {
            debug.err("Batch overflow! Consider increasing MAX_BATCH_OPS", .{});
            return error.BatchFull;
        }
        
        debug.warn("Auto-flushing at {} ops", .{self.count});
        self.executeNoFlush();
        _ = xcb.xcb_flush(self.wm.conn);
        self.count = 0;
        self.ops[0] = op;
        self.count = 1;
    }

    pub inline fn map(self: *Batch, win: u32) !void {
        try self.pushOp(.{ .map = win });
    }

    pub inline fn unmap(self: *Batch, win: u32) !void {
        try self.pushOp(.{ .unmap = win });
    }

    pub inline fn configure(self: *Batch, win: u32, rect: utils.Rect) !void {
        try self.pushOp(.{ .configure = .{ .win = win, .rect = rect } });
    }

    pub inline fn setBorder(self: *Batch, win: u32, color: u32) !void {
        try self.pushOp(.{ .set_border = .{ .win = win, .color = color } });
    }

    pub inline fn setBorderWidth(self: *Batch, win: u32, width: u16) !void {
        try self.pushOp(.{ .set_border_width = .{ .win = win, .width = width } });
    }

    pub inline fn setFocus(self: *Batch, win: u32) !void {
        focus.setFocus(self.wm, win, .tiling_operation);
    }

    pub inline fn raise(self: *Batch, win: u32) !void {
        try self.pushOp(.{ .raise = win });
    }

    pub fn execute(self: *Batch) void {
        self.executeNoFlush();
        _ = xcb.xcb_flush(self.wm.conn);
    }

    pub fn executeNoFlush(self: *Batch) void {
        const conn = self.wm.conn;
        
        // OPTIMIZATION: Direct array access with known bounds
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const op = self.ops[i];
            switch (op) {
                .map => |win| _ = xcb.xcb_map_window(conn, win),
                .unmap => |win| _ = xcb.xcb_unmap_window(conn, win),
                .configure => |cfg| {
                    // OPTIMIZATION: Inline configure to avoid function call overhead
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
                .raise => |win| _ = xcb.xcb_configure_window(conn, win, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE}),
            }
        }
    }
};
