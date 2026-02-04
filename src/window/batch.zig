//! Batch XCB operations for better performance

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");
const focus = @import("focus");

const XcbOp = union(enum) {
    map: u32,
    unmap: u32,
    configure: struct { win: u32, rect: utils.Rect },
    set_border: struct { win: u32, color: u32 },
    set_border_width: struct { win: u32, width: u16 },
    raise: u32,
    // Note: set_focus removed - now called directly through focus module
};

// 256 operations = ~16KB stack (well within safe limits)
const MAX_BATCH_OPS = 256;
const AUTO_FLUSH_THRESHOLD = 200;  // Auto-flush at ~80% capacity to prevent overflow

pub const Batch = struct {
    wm: *WM,
    ops: [MAX_BATCH_OPS]XcbOp,
    count: usize,
    auto_flushed: usize = 0,  // Track auto-flush count for debugging

    pub fn begin(wm: *WM) !Batch {
        return .{
            .wm = wm,
            .ops = undefined,
            .count = 0,
            .auto_flushed = 0,
        };
    }

    pub inline fn deinit(self: *Batch) void {
        if (self.auto_flushed > 0) {
            std.log.debug("[batch] Stats: {} operations, {} auto-flush(es)", 
                .{ self.count, self.auto_flushed });
        }
    }

    inline fn pushOp(self: *Batch, op: XcbOp) !void {
        // Auto-flush when approaching capacity to prevent overflow
        if (self.count >= AUTO_FLUSH_THRESHOLD) {
            std.log.warn("[batch] Auto-flushing at {} ops (capacity: {})", 
                .{ self.count, MAX_BATCH_OPS });
            self.executeNoFlush();
            _ = xcb.xcb_flush(self.wm.conn);
            self.count = 0;
            self.auto_flushed += 1;
        }
        
        if (self.count >= MAX_BATCH_OPS) {
            std.log.err("[batch] Batch overflow! Consider increasing MAX_BATCH_OPS", .{});
            return error.BatchFull;
        }
        
        self.ops[self.count] = op;
        self.count += 1;
    }

    pub fn map(self: *Batch, win: u32) !void {
        try self.pushOp(.{ .map = win });
    }

    pub fn unmap(self: *Batch, win: u32) !void {
        try self.pushOp(.{ .unmap = win });
    }

    pub fn configure(self: *Batch, win: u32, rect: utils.Rect) !void {
        try self.pushOp(.{ .configure = .{ .win = win, .rect = rect } });
    }

    pub fn setBorder(self: *Batch, win: u32, color: u32) !void {
        try self.pushOp(.{ .set_border = .{ .win = win, .color = color } });
    }

    pub fn setBorderWidth(self: *Batch, win: u32, width: u16) !void {
        try self.pushOp(.{ .set_border_width = .{ .win = win, .width = width } });
    }

    pub fn setFocus(self: *Batch, win: u32) !void {
        // Focus has important side effects (bar updates, tiling integration, protection)
        // Call focus module directly instead of batching the raw XCB operation
        focus.setFocus(self.wm, win, .tiling_operation);
    }

    pub fn raise(self: *Batch, win: u32) !void {
        try self.pushOp(.{ .raise = win });
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
                .raise => |win| _ = xcb.xcb_configure_window(conn, win, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE}),
            }
        }
    }
};
