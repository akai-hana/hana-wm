//! Core window tracking — always present, no optionality.
//!
//! Owns the window→workspace bitmask map and the current-workspace cursor.
//! Every other module queries window membership and focus eligibility through
//! this module, which means those predicates work correctly even when the full
//! workspace-switching subsystem (workspaces.zig) is not compiled in.
//!
//! workspaces.zig calls setCurrentWorkspace() and setWorkspaceCount() on every
//! switch and init respectively, keeping the state here in sync with the
//! multi-workspace feature when it is present.  When workspaces.zig is absent
//! the WM operates as a single-workspace session: all windows land on
//! workspace 0 and getCurrentWorkspace() always returns 0.

const std           = @import("std");
const build_options = @import("build_options");
const minimize      = if (build_options.has_minimize) @import("minimize") else struct {};

// ── Fixed-size ordered window list ────────────────────────────────────────────
// Used by Workspace in workspaces.zig; kept here so it can be imported from
// the always-present tracking module rather than the optional workspaces module.

pub const Tracking = struct {
    const capacity = 64;

    buf: [capacity]u32 = undefined,
    len: u8            = 0,

    pub fn contains(self: *const Tracking, win: u32) bool {
        return std.mem.indexOfScalar(u32, self.buf[0..self.len], win) != null;
    }

    fn prepareAdd(self: *Tracking, win: u32) bool {
        if (self.contains(win)) return false;
        if (self.len >= capacity) return false;
        return true;
    }

    pub fn add(self: *Tracking, win: u32) void {
        if (!self.prepareAdd(win)) return;
        self.buf[self.len] = win;
        self.len += 1;
    }

    pub fn addFront(self: *Tracking, win: u32) void {
        if (!self.prepareAdd(win)) return;
        std.mem.copyBackwards(u32, self.buf[1 .. self.len + 1], self.buf[0..self.len]);
        self.buf[0] = win;
        self.len += 1;
    }

    pub fn remove(self: *Tracking, win: u32) bool {
        const i = std.mem.indexOfScalar(u32, self.buf[0..self.len], win) orelse return false;
        std.mem.copyForwards(u32, self.buf[i .. self.len - 1], self.buf[i + 1 .. self.len]);
        self.len -= 1;
        return true;
    }

    pub fn removeUnordered(self: *Tracking, win: u32) bool {
        const i = std.mem.indexOfScalar(u32, self.buf[0..self.len], win) orelse return false;
        self.buf[i] = self.buf[self.len - 1];
        self.len   -= 1;
        return true;
    }

    pub fn reorder(self: *Tracking, new_order: []const u32) void {
        std.debug.assert(new_order.len == self.len);
        for (new_order) |w|
            std.debug.assert(self.contains(w));
        for (self.buf[0..self.len]) |w|
            std.debug.assert(std.mem.indexOfScalar(u32, new_order, w) != null);
        @memcpy(self.buf[0..self.len], new_order);
    }

    pub fn items(self: *const Tracking) []const u32 {
        return self.buf[0..self.len];
    }
};

// ── Global tracking state ─────────────────────────────────────────────────────

var g_map:             ?std.AutoHashMap(u32, u64) = null;
var g_current:         u8                         = 0;
var g_workspace_count: usize                      = 1;

pub fn init(allocator: std.mem.Allocator) void {
    var map = std.AutoHashMap(u32, u64).init(allocator);
    map.ensureTotalCapacity(32) catch {};
    g_map = map;
}

pub fn deinit() void {
    if (g_map) |*m| m.deinit();
    g_map             = null;
    g_current         = 0;
    g_workspace_count = 1;
}

/// Called by workspaces.init — tells tracking how many workspaces exist.
pub fn setWorkspaceCount(count: usize) void { g_workspace_count = count; }

/// Called by workspaces.switchTo so getCurrentWorkspace() stays correct
/// even when code queries tracking directly.
pub fn setCurrentWorkspace(ws: u8) void { g_current = ws; }

// ── Window registration ───────────────────────────────────────────────────────

/// Register `win` on workspace `ws`. No-op if already tracked.
/// Called directly when workspaces.zig is absent; workspaces.moveWindowTo
/// handles the full registration path (screen effects etc.) when present.
pub fn registerWindow(win: u32, ws: u8) !void {
    var map = &(g_map orelse return);
    if (map.contains(win)) return;
    try map.ensureUnusedCapacity(1);
    map.putAssumeCapacity(win, @as(u64, 1) << @intCast(ws));
}

/// Remove `win` from the tracking map.
/// When workspaces.zig is present it calls this after cleaning up workspace
/// Tracking arrays; when absent, window.zig calls this directly.
pub fn removeWindow(win: u32) void {
    if (g_map) |*m| _ = m.remove(win);
}

/// Update the workspace bitmask for `win`. Called by workspaces.zig for
/// tag and move operations; keeps the hashmap in sync with workspace arrays.
pub fn setWindowMask(win: u32, mask: u64) void {
    std.debug.assert(mask != 0);
    if (g_map) |*m| if (m.getPtr(win)) |p| { p.* = mask; };
}

// ── Query predicates ─────────────────────────────────────────────────────────

pub inline fn getWindowWorkspaceMask(win: u32) ?u64 {
    const m = g_map orelse return null;
    return m.get(win);
}

pub fn isManaged(win: u32) bool {
    return getWindowWorkspaceMask(win) != null;
}

pub inline fn windowCount() usize {
    return if (g_map) |m| m.count() else 0;
}

pub inline fn getCurrentWorkspace() ?u8 {
    if (g_map == null) return null;
    return g_current;
}

pub inline fn getWorkspaceCount() usize {
    return g_workspace_count;
}

pub inline fn getWorkspaceForWindow(win: u32) ?u8 {
    const mask = getWindowWorkspaceMask(win) orelse return null;
    return @intCast(@ctz(mask));
}

pub inline fn isWindowOnWorkspace(win: u32, ws_idx: u8) bool {
    const mask = getWindowWorkspaceMask(win) orelse return false;
    return (mask >> @intCast(ws_idx)) & 1 != 0;
}

pub inline fn isOnCurrentWorkspace(win: u32) bool {
    return isWindowOnWorkspace(win, g_current);
}

/// Combined predicate for focus recovery: on current workspace and not minimized.
/// Declared as a plain fn (not inline) so it can be passed as a *const fn(u32)bool.
pub fn isOnCurrentWorkspaceAndVisible(win: u32) bool {
    if (!isOnCurrentWorkspace(win)) return false;
    return if (comptime build_options.has_minimize) !minimize.isMinimized(win) else true;
}

/// Returns the first non-minimized window in `windows`, or null if all minimized.
/// Declared as a plain fn so minimize.zig can store it as a function pointer.
pub fn firstNonMinimized(windows: []const u32) ?u32 {
    for (windows) |win| {
        const is_min = if (comptime build_options.has_minimize) minimize.isMinimized(win) else false;
        if (!is_min) return win;
    }
    return null;
}
