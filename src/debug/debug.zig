//! Everything debug-related: error handling and logging.
//! Includes automatic tagging based on filenames (ex. "[window.zig] Error at ...")
//! Using build_options to check optimization mode,
//! for debug calls to only be active when built with -Doptimize=Debug.

const std = @import("std");
const build_options = @import("build_options");

/// Extract module name from source location.
/// Since these functions are `inline`, @src() inside them captures the call
/// site's source location — so the returned name is always the caller's module.
fn moduleFromSrc(src: std.builtin.SourceLocation) []const u8 {
    const basename = std.fs.path.basename(src.file);
    return if (std.mem.endsWith(u8, basename, ".zig"))
        basename[0 .. basename.len - 4]
    else
        basename;
}

/// Check if debug logging is enabled
inline fn debug_enabled() bool {
    return build_options.enable_debug_logging;
}

// ============================================================================
// Core logging — module tag is prepended via "[{s}] " ++ fmt so that only
// comptime-known values are concatenated with ++.
// ============================================================================

pub inline fn err(comptime fmt: []const u8, args: anytype) void {
    if (!debug_enabled()) return;
    const module = moduleFromSrc(@src());
    std.log.err("[{s}] " ++ fmt, .{module} ++ args);
}

pub inline fn warn(comptime fmt: []const u8, args: anytype) void {
    if (!debug_enabled()) return;
    const module = moduleFromSrc(@src());
    std.log.warn("[{s}] " ++ fmt, .{module} ++ args);
}

pub inline fn info(comptime fmt: []const u8, args: anytype) void {
    if (!debug_enabled()) return;
    const module = moduleFromSrc(@src());
    std.log.info("[{s}] " ++ fmt, .{module} ++ args);
}

pub inline fn debug(comptime fmt: []const u8, args: anytype) void {
    if (!debug_enabled()) return;
    const module = moduleFromSrc(@src());
    std.log.debug("[{s}] " ++ fmt, .{module} ++ args);
}

pub inline fn errIf(condition: bool, comptime fmt: []const u8, args: anytype) void {
    if (!debug_enabled() or !condition) return;
    const module = moduleFromSrc(@src());
    std.log.err("[{s}] " ++ fmt, .{module} ++ args);
}

pub inline fn warnIf(condition: bool, comptime fmt: []const u8, args: anytype) void {
    if (!debug_enabled() or !condition) return;
    const module = moduleFromSrc(@src());
    std.log.warn("[{s}] " ++ fmt, .{module} ++ args);
}

pub inline fn infoIf(condition: bool, comptime fmt: []const u8, args: anytype) void {
    if (!debug_enabled() or !condition) return;
    const module = moduleFromSrc(@src());
    std.log.info("[{s}] " ++ fmt, .{module} ++ args);
}

pub inline fn debugIf(condition: bool, comptime fmt: []const u8, args: anytype) void {
    if (!debug_enabled() or !condition) return;
    const module = moduleFromSrc(@src());
    std.log.debug("[{s}] " ++ fmt, .{module} ++ args);
}

pub inline fn assert(condition: bool, comptime message: []const u8) void {
    if (!debug_enabled() or condition) return;
    const module = moduleFromSrc(@src());
    std.debug.panic("[{s}] Assertion failed: {s}", .{ module, message });
}

pub inline fn trace(comptime func_name: []const u8) void {
    if (!debug_enabled()) return;
    const module = moduleFromSrc(@src());
    std.log.debug("[{s}] -> {s}", .{ module, func_name });
}

pub inline fn print(comptime label: []const u8, value: anytype) void {
    if (!debug_enabled()) return;
    const module = moduleFromSrc(@src());
    std.log.debug("[{s}] {s} = {any}", .{ module, label, value });
}

// ============================================================================
// Consolidated error-handling helpers
// ============================================================================

/// Log a structured error with an optional window ID for context.
///
/// Use this as the single canonical pattern wherever an operation fails
/// and you have (or might have) an associated window:
///
///   s.windows.add(win) catch |e| { debug.logError(e, win); return; };
///   StateManager.init(...) catch |e| { debug.logError(e, null); return; };
///
/// Replaces ad-hoc `logError` helpers that were previously defined
/// per-module (e.g. the private one in tiling.zig).
pub inline fn logError(e: anyerror, window: ?u32) void {
    if (!debug_enabled()) return;
    if (window) |win| {
        std.log.err("[error] Failed: {} (window: 0x{x})", .{ e, win });
    } else {
        std.log.err("[error] Failed: {}", .{e});
    }
}

/// Log a warning for a best-effort operation that failed but whose
/// failure is non-fatal and expected to be silent in release builds.
///
/// Use this instead of bare `catch {}` whenever an operation is
/// best-effort (e.g. cache puts, pre-allocations, rollback attempts)
/// but you still want visibility in debug builds:
///
///   self.geometry_cache.put(win, rect) catch |e| debug.warnOnErr(e, "geometry cache");
///   s.workspaces[from_ws].add(win)    catch |e| debug.warnOnErr(e, "workspace rollback");
///
/// Truly inconsequential capacity hints (ensureTotalCapacity, etc.) may
/// keep bare `catch {}` — they produce no useful diagnostic information.
pub inline fn warnOnErr(e: anyerror, comptime context: []const u8) void {
    if (!debug_enabled()) return;
    std.log.warn("[warn] Best-effort op failed (" ++ context ++ "): {}", .{e});
}
