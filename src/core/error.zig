// Error handling utilities
const std = @import("std");
const defs = @import("defs");
const Config = defs.Config;
// Use xcb from defs to avoid type conflicts
const xcb = defs.xcb;

// ANSI color codes
const COLOR_YELLOW = "\x1b[33m";
const COLOR_RED = "\x1b[31m";
const COLOR_RESET = "\x1b[0m";

// Loads config with fallback to defaults and user-friendly error messages
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

// Prints user-friendly error message for config loading failures
fn handleConfigError(err: anyerror, path: []const u8) void {
    switch (err) {
        error.FileNotFound => {
            std.debug.print("{s}Warning{s}: Config file '{s}' not found, falling back to defaults\n", .{ COLOR_YELLOW, COLOR_RESET, path });
        },
        error.AccessDenied => {
            std.debug.print("{s}Error{s}: Cannot access config file '{s}' (permission denied), falling back to defaults\n", .{ COLOR_RED, COLOR_RESET, path });
        },
        error.IsDir => {
            std.debug.print("{s}Error{s}: Config path '{s}' is a directory, not a file, falling back to defaults\n", .{ COLOR_RED, COLOR_RESET, path });
        },
        else => {
            std.debug.print("{s}Error{s}: Failed to load config '{s}' ({}), falling back to defaults\n", .{ COLOR_RED, COLOR_RESET, path, err });
        },
    }
}

// Warns about empty config value
pub fn warnEmptyValue(line: usize, key: []const u8) void {
    std.debug.print("{s}Warning{s} (line {}): Empty value for '{s}', falling back to defaults\n", .{ COLOR_YELLOW, COLOR_RESET, line, key });
}

// Warns about invalid border_width value
pub fn warnInvalidBorderWidth(line: usize, value: []const u8, err: anyerror) void {
    std.debug.print("{s}Warning{s} (line {}): Invalid border_width '{s}' ({}), falling back to defaults\n", .{ COLOR_YELLOW, COLOR_RESET, line, value, err });
}

// Warns about invalid border_color value
pub fn warnInvalidBorderColor(line: usize, value: []const u8, err: anyerror) void {
    std.debug.print("{s}Warning{s} (line {}): Invalid border_color '{s}' ({}), falling back to defaults\n", .{ COLOR_YELLOW, COLOR_RESET, line, value, err });
}

// Warns about duplicate config key
pub fn warnDuplicateKey(line: usize, key: []const u8) void {
    std.debug.print("{s}Warning{s} (line {}): Duplicate key '{s}', last value will be used\n", .{ COLOR_YELLOW, COLOR_RESET, line, key });
}

// Warns about color value exceeding RGB range
pub fn warnColorOutOfRange(line: usize, value: []const u8) void {
    std.debug.print("{s}Warning{s} (line {}): Color value '{s}' exceeds 24-bit RGB range (0x000000-0xFFFFFF), falling back to defaults\n", .{ COLOR_YELLOW, COLOR_RESET, line, value });
}

// Warns about unknown config key (potential typo)
pub fn warnUnknownConfigKey(line: usize, key: []const u8) void {
    std.debug.print("{s}Warning{s} (line {}): Unknown config key '{s}' (ignored)\n", .{ COLOR_YELLOW, COLOR_RESET, line, key });
}

// Connects to X11 display server with error handling
pub fn connectToX11() !*xcb.xcb_connection_t {
    const conn = xcb.xcb_connect(null, null) orelse {
        std.debug.print("{s}Error{s}: Failed to connect to X11 display server (null connection)\n", .{ COLOR_RED, COLOR_RESET });
        return error.X11ConnectionFailed;
    };
    if (xcb.xcb_connection_has_error(conn) != 0) {
        std.debug.print("{s}Error{s}: Failed to connect to X11 display server (connection error)\n", .{ COLOR_RED, COLOR_RESET });
        return error.X11ConnectionFailed;
    }
    return conn;
}

// Gets X11 screen with error handling
pub fn getX11Screen(conn: *xcb.xcb_connection_t) !*xcb.xcb_screen_t {
    const setup = xcb.xcb_get_setup(conn);
    const screen_iter = xcb.xcb_setup_roots_iterator(setup);
    const screen = screen_iter.data;
    if (screen == null) {
        std.debug.print("{s}Error{s}: Failed to get X11 screen\n", .{ COLOR_RED, COLOR_RESET });
        return error.X11ScreenFailed;
    }
    return screen;
}

// Attempts to become the window manager by claiming root window control
pub fn becomeWindowManager(conn: *xcb.xcb_connection_t, root: u32, event_mask: u32) !void {
    const mask = xcb.XCB_CW_EVENT_MASK;
    const values = [_]u32{event_mask};
    const cookie = xcb.xcb_change_window_attributes_checked(conn, root, mask, &values);
    const err = xcb.xcb_request_check(conn, cookie);
    if (err != null) {
        std.debug.print("{s}Error{s}: Another window manager is already running\n", .{ COLOR_RED, COLOR_RESET });
        return error.AnotherWMRunning;
    }
}

// Future error handling utilities can go here:
// - handleModuleError()
// - handleKeybindError()
// etc.
