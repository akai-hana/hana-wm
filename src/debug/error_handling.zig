// Error handling and reporting utilities
const std    = @import("std");
const defs   = @import("defs");
const colors = @import("colors");
const Config = defs.Config;
const xcb    = defs.xcb;

// CONFIG ERROR HANDLING

/// Loads config with fallback to defaults and user-friendly error messages
pub fn loadConfigOrDefault(
    loadConfig: fn (std.mem.Allocator, []const u8) anyerror!Config,
    allocator: std.mem.Allocator,
    path: []const u8,
    default_config: Config,
) Config {
    return loadConfig(allocator, path) catch |err| {
        handleConfigError(err, path);
        return default_config;
    };
}

/// Prints user-friendly error message for config loading failures
fn handleConfigError(err: anyerror, path: []const u8) void {
    const msg = switch (err) {
        error.FileNotFound => "not found",
        error.AccessDenied => "permission denied",
        error.IsDir => "is a directory, not a file",
        else => "unknown error",
    };
    const color = if (err == error.FileNotFound) colors.YELLOW else colors.RED;
    std.debug.print("{s}Warning{s}: Config file '{s}' {s}, falling back to defaults\n",
        .{ color, colors.RESET, path, msg });
}

// CONFIG WARNING FUNCTIONS

pub fn warnEmptyValue(line: usize, key: []const u8) void {
    std.debug.print("{s}Warning{s} (line {}): Empty value for '{s}', falling back to defaults\n",
        .{ colors.YELLOW, colors.RESET, line, key });
}

pub fn warnInvalidBorderWidth(line: usize, value: []const u8, err: anyerror) void {
    std.debug.print("{s}Warning{s} (line {}): Invalid border_width '{s}' ({}), falling back to defaults\n",
        .{ colors.YELLOW, colors.RESET, line, value, err });
}

pub fn warnInvalidBorderColor(line: usize, value: []const u8, err: anyerror) void {
    std.debug.print("{s}Warning{s} (line {}): Invalid border_color '{s}' ({}), falling back to defaults\n",
        .{ colors.YELLOW, colors.RESET, line, value, err });
}

pub fn warnDuplicateKey(line: usize, key: []const u8) void {
    std.debug.print("{s}Warning{s} (line {}): Duplicate key '{s}', last value will be used\n",
        .{ colors.YELLOW, colors.RESET, line, key });
}

pub fn warnColorOutOfRange(line: usize, value: []const u8) void {
    std.debug.print("{s}Warning{s} (line {}): Color value '{s}' exceeds 24-bit RGB range (0x000000-0xFFFFFF), falling back to defaults\n",
        .{ colors.YELLOW, colors.RESET, line, value });
}

pub fn warnUnknownConfigKey(line: usize, key: []const u8) void {
    std.debug.print("{s}Warning{s} (line {}): Unknown config key '{s}' (ignored)\n",
        .{ colors.YELLOW, colors.RESET, line, key });
}

// X11 ERROR HANDLING

pub fn connectToX11() !*xcb.xcb_connection_t {
    const conn = xcb.xcb_connect(null, null) orelse {
        std.debug.print("{s}Error{s}: Failed to connect to X11 display server (null connection)\n",
            .{ colors.RED, colors.RESET });
        return error.X11ConnectionFailed;
    };
    if (xcb.xcb_connection_has_error(conn) != 0) {
        std.debug.print("{s}Error{s}: Failed to connect to X11 display server (connection error)\n",
            .{ colors.RED, colors.RESET });
        return error.X11ConnectionFailed;
    }
    return conn;
}

pub fn getX11Screen(conn: *xcb.xcb_connection_t) !*xcb.xcb_screen_t {
    const setup = xcb.xcb_get_setup(conn);
    const screen = xcb.xcb_setup_roots_iterator(setup).data orelse {
        std.debug.print("{s}Error{s}: Failed to get X11 screen\n", .{ colors.RED, colors.RESET });
        return error.X11ScreenFailed;
    };
    return screen;
}

pub fn becomeWindowManager(conn: *xcb.xcb_connection_t, root: u32, event_mask: u32) !void {
    const cookie = xcb.xcb_change_window_attributes_checked(conn, root, xcb.XCB_CW_EVENT_MASK, &[_]u32{event_mask});
    if (xcb.xcb_request_check(conn, cookie)) |_| {
        std.debug.print("{s}Error{s}: Another window manager is already running\n", .{ colors.RED, colors.RESET });
        return error.AnotherWMRunning;
    }
}

/// Check XCB request for errors and log them
pub fn xcbCheckError(conn: *xcb.xcb_connection_t, cookie: xcb.xcb_void_cookie_t, operation: []const u8) bool {
    if (xcb.xcb_request_check(conn, cookie)) |err| {
        std.log.err("[XCB] {s} failed: error_code={}", .{operation, err.*.error_code});
        std.c.free(err);
        return false;
    }
    return true;
}
