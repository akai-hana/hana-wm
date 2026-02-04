/// XCB operations wrapper
/// Provides consistent error handling and cleaner API for X11 operations

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;

pub const XcbOps = struct {
    conn: *xcb.xcb_connection_t,
    
    /// Initialize XcbOps wrapper
    pub inline fn init(conn: *xcb.xcb_connection_t) XcbOps {
        return .{ .conn = conn };
    }
    
    /// Configure window with error checking
    pub fn configureWindow(
        self: XcbOps,
        win: u32,
        mask: u16,
        values: []const u32
    ) !void {
        const cookie = xcb.xcb_configure_window_checked(self.conn, win, mask, values.ptr);
        if (xcb.xcb_request_check(self.conn, cookie)) |err| {
            defer std.c.free(err);
            std.log.err("[xcb] Configure window 0x{x} failed: error_code={}", 
                .{ win, err.*.error_code });
            return error.XcbConfigureFailed;
        }
    }
    
    /// Change window attributes with error checking
    pub fn changeWindowAttributes(
        self: XcbOps,
        win: u32,
        mask: u32,
        values: []const u32
    ) !void {
        const cookie = xcb.xcb_change_window_attributes_checked(self.conn, win, mask, values.ptr);
        if (xcb.xcb_request_check(self.conn, cookie)) |err| {
            defer std.c.free(err);
            std.log.err("[xcb] Change attributes for window 0x{x} failed: error_code={}", 
                .{ win, err.*.error_code });
            return error.XcbAttributeChangeFailed;
        }
    }
    
    /// Set border color (unchecked for performance in hot paths)
    pub inline fn setBorderUnchecked(self: XcbOps, win: u32, color: u32) void {
        _ = xcb.xcb_change_window_attributes(self.conn, win, 
            xcb.XCB_CW_BORDER_PIXEL, &[_]u32{color});
    }
    
    /// Set border width (unchecked for performance in hot paths)
    pub inline fn setBorderWidthUnchecked(self: XcbOps, win: u32, width: u16) void {
        _ = xcb.xcb_configure_window(self.conn, win, 
            xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{width});
    }
    
    /// Map window (unchecked for performance)
    pub inline fn mapWindowUnchecked(self: XcbOps, win: u32) void {
        _ = xcb.xcb_map_window(self.conn, win);
    }
    
    /// Unmap window (unchecked for performance)
    pub inline fn unmapWindowUnchecked(self: XcbOps, win: u32) void {
        _ = xcb.xcb_unmap_window(self.conn, win);
    }
    
    /// Raise window (unchecked for performance)
    pub inline fn raiseWindowUnchecked(self: XcbOps, win: u32) void {
        _ = xcb.xcb_configure_window(self.conn, win, 
            xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    }
    
    /// Set input focus (unchecked for performance)
    pub inline fn setInputFocusUnchecked(self: XcbOps, win: u32) void {
        _ = xcb.xcb_set_input_focus(self.conn, 
            xcb.XCB_INPUT_FOCUS_POINTER_ROOT, win, xcb.XCB_CURRENT_TIME);
    }
    
    /// Flush connection
    pub inline fn flush(self: XcbOps) void {
        _ = xcb.xcb_flush(self.conn);
    }
    
    /// Destroy window (unchecked)
    pub inline fn destroyWindowUnchecked(self: XcbOps, win: u32) void {
        _ = xcb.xcb_destroy_window(self.conn, win);
    }
};

/// Helper to create XcbOps from connection pointer
pub inline fn wrap(conn: *xcb.xcb_connection_t) XcbOps {
    return XcbOps.init(conn);
}
