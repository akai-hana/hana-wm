// Debug logging utilities for the window manager
const std = @import("std");
const builtin = @import("builtin");
const colors = @import("colors");

/// Generic debug print - only prints in Debug mode
pub inline fn debugPrint(comptime fmt: []const u8, args: anytype) void {
    if (builtin.mode == .Debug) {
        std.debug.print(fmt, args);
    }
}

// GENERIC LOGGING HELPERS

/// Log that a config value was set
pub fn debugConfigValue(comptime field: []const u8, comptime fmt: []const u8, args: anytype) void {
    std.log.info("[config] ✓ " ++ field ++ " = " ++ fmt, args);
}

/// Log that a config value is using default
pub fn debugConfigDefault(comptime field: []const u8, comptime fmt: []const u8, args: anytype) void {
    std.log.info("[config] ○ " ++ field ++ " not specified, using default: " ++ fmt, args);
}

/// Warn that a value is too low
pub fn warnValueTooLow(comptime field: []const u8, value: anytype, minimum: anytype) void {
    std.log.warn("[config] ✗ " ++ field ++ " {} is too low (minimum: {}), using default", .{value, minimum});
}

/// Warn that a value is too high
pub fn warnValueTooHigh(comptime field: []const u8, value: anytype, maximum: anytype) void {
    std.log.warn("[config] ✗ " ++ field ++ "={} seems excessive, capping at {}", .{value, maximum});
}

/// Warn that a value is out of range
pub fn warnValueOutOfRange(comptime field: []const u8, value: anytype, min: anytype, max: anytype) void {
    std.log.warn("[config] ✗ " ++ field ++ " {} out of range ({}-{}), using default", .{value, min, max});
}

/// Warn that a color value exceeds RGB range
pub fn warnColorOutOfRange(comptime field: []const u8, color: u32) void {
    std.log.warn("[config] ✗ " ++ field ++ " 0x{x} exceeds 24-bit RGB range", .{color});
}

// WM CORE DEBUG FUNCTIONS

pub fn debugWMStarted() void {
    debugPrint("{s}[WM]{s} hana window manager started\n", .{ colors.GREEN, colors.RESET });
}

pub fn debugKeybindingsGrabbed(count: usize) void {
    debugPrint("{s}[WM]{s} Grabbed {} keybindings\n", .{ colors.GREEN, colors.RESET, count });
}

pub fn debugConfigReloading() void {
    debugPrint("{s}[WM]{s} Reloading configuration...\n", .{ colors.CYAN, colors.RESET });
}

pub fn debugConfigReloaded() void {
    debugPrint("{s}[WM]{s} Configuration reloaded successfully\n", .{ colors.GREEN, colors.RESET });
}

pub fn debugCursorSetupFailed() void {
    debugPrint("{s}[cursor]{s} Failed to open font\n", .{ colors.RED, colors.RESET });
}

pub fn errorConfigReloadFailed(err: anyerror) void {
    std.log.err("Config reload failed: {}", .{err});
}

// CONFIG MODULE DEBUG FUNCTIONS

pub fn debugConfigNotFound(path: []const u8) void {
    std.log.info("Config file not found at '{s}', using defaults", .{path});
}

pub fn debugConfigLoaded(path: []const u8) void {
    std.log.info("Successfully loaded config from: {s}", .{path});
}

pub fn debugModVariableFound(mod_value: []const u8) void {
    std.log.info("Found Mod variable: {s}", .{mod_value});
}

pub fn debugKeybindingAction(action: []const u8) void {
    std.log.info("[config] Keybinding → {s} action", .{action});
}

pub fn debugKeybindingExec(command: []const u8) void {
    std.log.info("[config] Keybinding → exec command: {s}", .{command});
}

pub fn debugTilingSectionNotFound() void {
    std.log.info("[config] No [tiling] section found, using defaults", .{});
}

pub fn debugTilingParseStart() void {
    std.log.info("[config] ========== PARSING TILING CONFIG ==========", .{});
}

pub fn debugTilingParseEnd() void {
}

// Tiling-specific helpers with proper formatting
pub fn debugTilingLayout(layout: []const u8) void {
    std.log.info("[config] ✓ layout = \"{s}\"", .{layout});
}

pub fn debugTilingLayoutDefault(layout: []const u8) void {
    std.log.info("[config] ○ layout not specified, using default: \"{s}\"", .{layout});
}

pub fn debugTilingMasterWidthFactor(factor: i64, actual: f32) void {
    std.log.info("[config] ✓ master_width_factor = {}% ({d:.2})", .{factor, actual});
}

pub fn debugTilingMasterWidthFactorDefault(factor: f32) void {
    std.log.info("[config] ○ master_width_factor not specified, using default: {d:.0}%", .{factor * 100});
}

pub fn debugTilingBorderColor(comptime field: []const u8, color: u32) void {
    std.log.info("[config] ✓ " ++ field ++ " = #0x{x:0>6}", .{color});
}

pub fn debugTilingBorderColorDefault(comptime field: []const u8, color: u32) void {
    std.log.info("[config] ○ " ++ field ++ " not specified, using default: #0x{x:0>6}", .{color});
}

// Config Module Warning Functions
pub fn warnKeybindingValueNotString(key: []const u8) void {
    std.log.warn("Keybinding value must be a string: {s}", .{key});
}

pub fn warnInvalidKeybinding(key: []const u8, err: anyerror) void {
    std.log.warn("Invalid keybinding '{s}': {}", .{key, err});
}

pub fn warnUnknownKeyName(name: []const u8) void {
    std.log.warn("Unknown key name: {s}", .{name});
}

pub fn warnKeycodeNotFound(keysym: u32) void {
    std.log.warn("Could not find keycode for keysym 0x{x}", .{keysym});
}

pub fn errorDuplicateKeybinding(modifiers: u16, keysym: u32) void {
    std.log.err("Duplicate keybinding: mod={x} keysym={d}", .{modifiers, keysym});
}

// XKB MODULE DEBUG FUNCTIONS

pub fn debugXkbInitializing() void {
    std.log.info("Initializing XKB...", .{});
}

pub fn debugXkbDeviceId(device_id: i32) void {
    std.log.info("Keyboard device ID: {}", .{device_id});
}

pub fn debugXkbInitComplete() void {
    std.log.info("XKB initialization complete", .{});
}

pub fn warnXkbKeycodeNotFound(keysym: u32) void {
    std.log.warn("Could not find keycode for keysym 0x{x}", .{keysym});
}

// WINDOW MODULE DEBUG FUNCTIONS

pub fn debugWindowModuleInit() void {
    debugPrint("[window] Module initialized\n", .{});
}

pub fn debugWindowMapRequest(window_id: u32) void {
    debugPrint("{s}[window]{s} Map request for window {x}\n", .{ colors.BLUE, colors.RESET, window_id });
}

pub fn debugWindowConfigure(window_id: u32, width: u16, height: u16, x: i16, y: i16) void {
    debugPrint("{s}[window]{s} Configure: window {x} -> {}x{} at ({},{})\n",
        .{ colors.BLUE, colors.RESET, window_id, width, height, x, y });
}

pub fn debugWindowDestroyed(window_id: u32) void {
    debugPrint("{s}[window]{s} Window {x} destroyed\n", .{ colors.BLUE, colors.RESET, window_id });
}

// INPUT MODULE DEBUG FUNCTIONS

pub fn debugInputModuleInit(keybind_count: usize) void {
    debugPrint("{s}[input]{s} Module initialized with {} keybindings\n", .{ colors.BLUE, colors.RESET, keybind_count });
}

pub fn debugKeybindingMatched(modifiers: u16, keysym: u32) void {
    debugPrint("{s}[input]{s} Keybinding matched: mod=0x{x} keysym=0x{x}\n", .{ colors.BLUE, colors.RESET, modifiers, keysym });
}

pub fn debugUnboundKey(keycode: u8, keysym: u32, modifiers: u16, raw_modifiers: u16) void {
    debugPrint("{s}[input]{s} Unbound key: keycode={} keysym=0x{x} mod=0x{x} (raw=0x{x})\n", .{ colors.BLUE, colors.RESET, keycode, keysym, modifiers, raw_modifiers });
}

pub fn debugExecutingCommand(cmd: []const u8) void {
    debugPrint("{s}[input]{s} Executing: {s}\n", .{ colors.BLUE, colors.RESET, cmd });
}

pub fn debugExecutingAction(comptime action: []const u8) void {
    std.log.info("[input] Executing " ++ action ++ " action", .{});
}

pub fn debugClosingWindow(window_id: u32) void {
    debugPrint("{s}[input]{s} Closing window {}\n", .{ colors.BLUE, colors.RESET, window_id });
}

pub fn debugNoFocusedWindow() void {
    debugPrint("{s}[input]{s} No focused window to close\n", .{ colors.YELLOW, colors.RESET });
}

pub fn debugConfigReloadTriggered() void {
    debugPrint("{s}[input]{s} Config reload triggered\n", .{ colors.BLUE, colors.RESET });
}

pub fn debugFocusNotImplemented() void {
    debugPrint("{s}[input]{s} Focus navigation not yet implemented\n", .{ colors.BLUE, colors.RESET });
}

pub fn debugMouseButtonClick(button: u8, x: i16, y: i16, window: u32) void {
    debugPrint("{s}[input]{s} Mouse button {} click at ({}, {}) window={}\n", .{ colors.BLUE, colors.RESET, button, x, y, window });
}

pub fn debugMouseButtonRelease(button: u8) void {
    debugPrint("{s}[input]{s} Mouse button {} released\n", .{ colors.BLUE, colors.RESET, button });
}

pub fn debugDragMotion(x: i16, y: i16) void {
    debugPrint("{s}[input]{s} Drag motion: ({}, {})\n", .{ colors.BLUE, colors.RESET, x, y });
}

pub fn errorKeybindMapBuildFailed(err: anyerror) void {
    std.log.err("Failed to build keybind map: {}", .{err});
}

pub fn errorKeybindMapRebuildFailed(err: anyerror) void {
    std.log.err("Failed to rebuild keybind map: {}", .{err});
}

pub fn errorActionExecutionFailed(err: anyerror) void {
    std.log.err("Failed to execute keybinding action: {}", .{err});
}

pub fn errorCommandForkFailed(cmd: []const u8) void {
    std.log.err("Fork failed for command: {s}", .{cmd});
}

// TILING MODULE DEBUG FUNCTIONS

pub fn debugTilingModuleInit() void {
    std.log.info("[tiling] ============ TILING CONFIGURATION ============", .{});
}

pub fn debugTilingModuleEnd() void {
}

pub fn debugTilingStateValue(comptime field: []const u8, comptime fmt: []const u8, args: anytype) void {
    std.log.info("[tiling] " ++ field ++ ": " ++ fmt, args);
}

pub fn debugTilingLayoutChange(layout_name: []const u8) void {
    debugPrint("[tiling] Layout changed to: {s}\n", .{layout_name});
}

pub fn debugTilingMasterWidthChange(old_percent: f32, new_percent: f32) void {
    std.log.info("[tiling] Master width: {d:.2}% → {d:.2}%", .{old_percent * 100, new_percent * 100});
}

pub fn debugTilingStatusChange(enabled: bool) void {
    const status = if (enabled) "enabled" else "disabled";
    debugPrint("[tiling] Tiling {s}\n", .{status});
}

pub fn debugTilingWindowAdded(window_id: u32, total: usize) void {
    debugPrint("[tiling] Window {x} added, total windows: {}\n", .{window_id, total});
}

pub fn debugTilingWindowRemoved(window_id: u32, remaining: usize) void {
    debugPrint("[tiling] Window {x} removed, remaining: {}\n", .{window_id, remaining});
}

pub fn debugTilingConfigIgnored(window_id: u32) void {
    debugPrint("[tiling] Ignoring configure request from tiled window {x}\n", .{window_id});
}

pub fn warnTilingUnknownLayout(layout_str: []const u8) void {
    std.log.warn("[tiling] Unknown layout '{s}', defaulting to master_left", .{layout_str});
}

pub fn errorTilingStateAllocationFailed() void {
    std.log.err("Failed to allocate tiling state", .{});
}

pub fn errorTilingWindowAddFailed() void {
    std.log.err("Failed to add window to tiling list", .{});
}

// LAYOUT MODULE DEBUG FUNCTIONS

pub fn debugLayoutTiling(comptime layout: []const u8, window_count: usize, cols: anytype, rows: anytype) void {
    debugPrint("[" ++ layout ++ "] Tiling {} windows in {}x{} grid\n", .{window_count, cols, rows});
}

pub fn debugLayoutTilingSimple(comptime layout: []const u8, window_count: usize) void {
    debugPrint("[" ++ layout ++ "] Tiling {} windows fullscreen\n", .{window_count});
}

pub fn debugLayoutMasterLeft(n: usize, master_count: usize, m_count: usize, s_count: usize, screen_w: u16) void {
    debugPrint("[master-left] n={}, master_count={}, m_count={}, s_count={}, screen_w={}\n",
        .{n, master_count, m_count, s_count, screen_w});
}

pub fn debugLayoutWindowGeometry(idx: usize, x: u16, y: u16, w: u16, h: u16, is_master: bool) void {
    debugPrint("[master-left] Window {}: x={}, y={}, w={}, h={} (master={})\n",
        .{idx, x, y, w, h, is_master});
}

pub fn debugWindowFocusChanged(window_id: u32) void {
    debugPrint("{s}[input]{s} Focus changed to window {x}\n", .{ colors.BLUE, colors.RESET, window_id });
}
