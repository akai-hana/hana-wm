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

// WM Core Debug Functions

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

// Input Module Debug Functions

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

pub fn debugClosingWindow(window_id: u32) void {
    debugPrint("{s}[input]{s} Closing window {}\n", .{ colors.BLUE, colors.RESET, window_id });
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
