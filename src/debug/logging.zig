//! Centralized logging for debugging and status messages.

const std = @import("std");
const builtin = @import("builtin");
const colors = @import("colors");

pub inline fn isDebug() bool {
    return builtin.mode == .Debug;
}

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

pub fn xkbInitializing() void {
    if (isDebug()) std.log.debug("[xkb] Initializing", .{});
}

pub fn xkbDeviceId(device_id: i32) void {
    if (isDebug()) std.log.debug("[xkb] Device ID: {}", .{device_id});
}

pub fn xkbInitComplete() void {
    if (isDebug()) std.log.debug("[xkb] Initialization complete", .{});
}

pub fn xkbKeycodeNotFound(keysym: u32) void {
    if (isDebug()) std.log.warn("[xkb] Keycode not found for keysym: 0x{x}", .{keysym});
}

pub fn focusChanged(old: ?u32, new: u32, reason: []const u8) void {
    if (isDebug()) std.log.debug("[focus] {?} → 0x{x} ({s})", .{ old, new, reason });
}

pub fn focusSuppressed(elapsed_ms: u64) void {
    if (isDebug()) std.log.debug("[focus] Suppressing mouse focus ({}ms since layout)", .{elapsed_ms});
}

pub fn focusLayoutMarked() void {
    if (isDebug()) std.log.debug("[focus] Layout operation marked", .{});
}

pub fn dragStarted(action: []const u8, window: u32, x: i16, y: i16) void {
    if (isDebug()) std.log.info("[drag] {s} window 0x{x} at ({}, {})", .{ action, window, x, y });
}

pub fn dragStopped(window: u32) void {
    if (isDebug()) std.log.info("[drag] Stopped window 0x{x}", .{window});
}

pub fn debugLayoutTiling(layout: []const u8, count: usize, cols: u16, rows: u16) void {
    if (isDebug()) std.log.debug("[layout:{s}] {} windows ({}x{})", .{ layout, count, cols, rows });
}

pub fn debugLayoutTilingSimple(layout: []const u8, count: usize) void {
    if (isDebug()) std.log.debug("[layout:{s}] {} windows", .{ layout, count });
}

pub fn debugLayoutMasterLeft(total: usize, master_count: usize, actual_master: u16, stack: u16, screen_w: u16) void {
    if (isDebug()) std.log.debug("[layout:master_left] {} windows (master_count={}, actual_master={}, stack={}, width={})", .{
        total, master_count, actual_master, stack, screen_w,
    });
}

pub fn debugLayoutWindowGeometry(idx: usize, x: u16, y: u16, w: u16, h: u16, is_master: bool) void {
    if (isDebug()) {
        const area = if (is_master) "master" else "stack";
        std.log.debug("[layout] Window {}: {}x{}+{}+{} ({})", .{ idx, w, h, x, y, area });
    }
}

pub fn configReloaded() void {
    std.log.info("[config] Reloaded", .{});
}

pub fn configReloadFailed(err: anyerror) void {
    std.log.err("[config] Reload failed: {}", .{err});
}

pub fn configLoaded(path: []const u8) void {
    std.log.info("[config] Loaded: {s}", .{path});
}

pub fn configNotFound(path: []const u8) void {
    std.log.info("[config] Not found: {s}, using defaults", .{path});
}

pub fn parserInvalidSection(line: usize, err: anyerror) void {
    std.log.warn("[parser] Invalid section at line {}: {}", .{ line, err });
}

pub fn parserDuplicateSection(line: usize) void {
    std.log.warn("[parser] Duplicate section at line {}", .{line});
}

pub fn parserInvalidKeyValue(line: usize, err: anyerror) void {
    std.log.warn("[parser] Invalid key-value at line {}: {}", .{ line, err });
}

pub fn parserDuplicateKey(key: []const u8, line: usize) void {
    std.log.warn("[parser] Duplicate key '{s}' at line {}", .{ key, line });
}

pub fn parserUnexpectedChar(line: usize) void {
    std.log.warn("[parser] Unexpected character at line {}", .{line});
}

pub fn parserInvalidColor(value: []const u8, line: usize) void {
    std.log.warn("[parser] Invalid color '{s}' at line {}", .{ value, line });
}

pub fn wmStarted() void {
    std.log.info("[hana] Started", .{});
}

pub fn dumpStateSeparator() void {
    std.log.info("========== STATE ==========", .{});
}

pub fn dumpStateEnd() void {
    std.log.info("===========================", .{});
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

pub fn emergencyRecoveryStart() void {
    std.log.warn("========== RECOVERY ==========", .{});
}

pub fn emergencyRecoveryComplete() void {
    std.log.warn("Recovery complete", .{});
}
