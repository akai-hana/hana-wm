//! Centralized logging and debugging utilities for Hana WM
const std = @import("std");
const builtin = @import("builtin");
const colors = @import("colors");

pub inline fn isDebug() bool {
    return builtin.mode == .Debug;
}

// CONFIG VALIDATION LOGGING

pub fn validateRange(comptime T: type, value: T, min: T, max: T, comptime field: []const u8) bool {
    if (value < min or value > max) {
        std.log.warn("[config] {s} {} out of range ({}-{})", .{ field, value, min, max });
        return false;
    }
    return true;
}

pub fn validateColor(color: u32, comptime field: []const u8) bool {
    if (color > 0xFFFFFF) {
        std.log.warn("[config] {s} 0x{x} exceeds RGB range", .{ field, color });
        return false;
    }
    return true;
}

// XKB LOGGING

pub fn xkbInitializing() void {
    if (isDebug()) {
        std.log.debug("[xkb] Initializing XKB", .{});
    }
}

pub fn xkbDeviceId(device_id: i32) void {
    if (isDebug()) {
        std.log.debug("[xkb] Device ID: {}", .{device_id});
    }
}

pub fn xkbInitComplete() void {
    if (isDebug()) {
        std.log.debug("[xkb] Initialization complete", .{});
    }
}

pub fn xkbKeycodeNotFound(keysym: u32) void {
    if (isDebug()) {
        std.log.warn("[xkb] Keycode not found for keysym: 0x{x}", .{keysym});
    }
}

// FOCUS LOGGING

pub fn focusChanged(old: ?u32, new: u32, reason: []const u8) void {
    if (isDebug()) {
        std.log.debug("[focus] {?} → 0x{x} ({s})", .{ old, new, reason });
    }
}

pub fn focusSuppressed(elapsed_ms: u64) void {
    if (isDebug()) {
        std.log.debug("[focus] Suppressing mouse focus ({}ms since layout)", .{elapsed_ms});
    }
}

pub fn focusLayoutMarked() void {
    if (isDebug()) {
        std.log.debug("[focus] Layout operation marked, starting grace period", .{});
    }
}

// DRAG LOGGING

pub fn dragStarted(action: []const u8, window: u32, x: i16, y: i16) void {
    if (isDebug()) {
        std.log.info("[drag] Started {s} on window {x} at ({}, {})", .{ action, window, x, y });
    }
}

pub fn dragStopped(window: u32) void {
    if (isDebug()) {
        std.log.info("[drag] Stopped dragging window {x}", .{window});
    }
}

// LAYOUT/TILING LOGGING

pub fn debugLayoutTiling(layout: []const u8, count: usize, cols: u16, rows: u16) void {
    if (isDebug()) {
        std.log.debug("[layout:{s}] Tiling {} windows ({}x{})", .{ layout, count, cols, rows });
    }
}

pub fn debugLayoutTilingSimple(layout: []const u8, count: usize) void {
    if (isDebug()) {
        std.log.debug("[layout:{s}] Tiling {} windows", .{ layout, count });
    }
}

pub fn debugLayoutMasterLeft(total: usize, master_count: usize, actual_master: u16, stack: u16, screen_w: u16) void {
    if (isDebug()) {
        std.log.debug("[layout:master_left] {} windows (master_count={}, actual_master={}, stack={}, screen_w={})", .{
            total,
            master_count,
            actual_master,
            stack,
            screen_w,
        });
    }
}

pub fn debugLayoutWindowGeometry(idx: usize, x: u16, y: u16, w: u16, h: u16, is_master: bool) void {
    if (isDebug()) {
        const area = if (is_master) "master" else "stack";
        std.log.debug("[layout] Window {}: x={} y={} w={} h={} ({})", .{ idx, x, y, w, h, area });
    }
}

// CONFIG RELOAD LOGGING

pub fn configReloaded() void {
    std.log.info("[config] Reloaded successfully", .{});
}

pub fn configReloadFailed(err: anyerror) void {
    std.log.err("Config reload failed: {}", .{err});
}

pub fn configLoaded(path: []const u8) void {
    std.log.info("[config] Loaded: {s}", .{path});
}

pub fn configNotFound(path: []const u8) void {
    std.log.info("[config] Not found: {s}, using defaults", .{path});
}

// PARSER LOGGING

pub fn parserInvalidSection(line: usize, err: anyerror) void {
    std.log.warn("[parser] Skipping invalid section at line {}: {}", .{ line, err });
}

pub fn parserDuplicateSection(line: usize) void {
    std.log.warn("[parser] Duplicate section at line {}, ignoring", .{line});
}

pub fn parserInvalidKeyValue(line: usize, err: anyerror) void {
    std.log.warn("[parser] Skipping invalid key-value at line {}: {any}", .{ line, err });
}

pub fn parserDuplicateKey(key: []const u8, line: usize) void {
    std.log.warn("[parser] Duplicate key '{s}' at line {}, using last value", .{ key, line });
}

pub fn parserUnexpectedChar(line: usize) void {
    std.log.warn("[parser] Unexpected character after value at line {}, skipping line", .{line});
}

pub fn parserInvalidColor(value: []const u8, line: usize) void {
    std.log.warn("[parser] Invalid color value '{s}' at line {}", .{ value, line });
}

pub fn parserInvalidConfigKey(line: usize, key: []const u8) void {
    std.log.warn("[parser] Invalid config key at line {}: {s}", .{ line, key });
}

// STARTUP LOGGING

pub fn wmStarted() void {
    std.log.info("[hana] Window manager started", .{});
}

// STATE DUMP LOGGING

pub fn dumpStateSeparator() void {
    std.log.info("========== WM STATE DUMP ==========", .{});
}

pub fn dumpStateEnd() void {
    std.log.info("===================================", .{});
}

pub fn dumpStateFocused(win: ?u32) void {
    std.log.info("Focused: {?}", .{win});
}

pub fn dumpStateTotalWindows(count: usize) void {
    std.log.info("Total windows: {}", .{count});
}

pub fn dumpStateCurrentWorkspace(ws: usize) void {
    std.log.info("Current workspace: {}", .{ws + 1});
}

pub fn dumpStateWorkspace(idx: usize, count: usize) void {
    std.log.info("  WS{}: {} windows", .{ idx + 1, count });
}

pub fn dumpStateTiling(enabled: bool, count: usize) void {
    std.log.info("Tiling: {} ({} windows)", .{ enabled, count });
}

// EMERGENCY RECOVERY LOGGING

pub fn emergencyRecoveryStart() void {
    std.log.warn("========== EMERGENCY RECOVERY ==========", .{});
}

pub fn emergencyRecoveryComplete() void {
    std.log.warn("Recovery complete", .{});
}
