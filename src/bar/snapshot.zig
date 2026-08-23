//! Bar snapshot layer (D2 decomposition of bar.zig).
//!
//! Owns the point-in-time WM state model the bar renders from:
//!   - data types: WindowTitles (per-slot arena), TitleData, BarSnapshot,
//!     TitleCache,
//!   - the capture/diff pipeline: captureStateIntoSlot and its helpers,
//!     including the ping-pong ownership relay between snapshot slots,
//!   - snapshotNeedsRefetch: the allocation-free prediction used by
//!     redrawInsideGrab to defer expensive captures out of server grabs.
//!
//! Functions take narrow parameters (allocator, caches, flags) instead of
//! bar's whole State so this module has no type dependency on bar.zig;
//! behavior is moved verbatim.

const std = @import("std");

const core = @import("core");
const utils = @import("utils");
const debug = @import("debug");
const bench = @import("bench");

const tracking = @import("tracking");
const focus = @import("focus");
const minimize = @import("minimize");
const pipeline = @import("pipeline");
const workspaces = @import("workspaces");

const title = @import("title");
const prompt = @import("prompt");

/// Per-window title strings backed by a per-slot arena: every string in
/// `list` is a slice into `arena`'s memory, so clearing/dropping a list is
/// one arena reset, and duping a batch bumps a pointer into owned pages
/// instead of hitting the system allocator per window. `list`'s own buffer
/// lives on the caller's allocator, separate from the arena so `clear` can
/// reset the arena without invalidating the retained buffer.
pub const WindowTitles = struct {
    arena: std.heap.ArenaAllocator = undefined,
    list: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn init(backing: std.mem.Allocator) WindowTitles {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    /// Allocator for title-string storage; bump-allocated and reclaimed by
    /// the next `clear`/`deinit`.
    pub fn allocator(self: *WindowTitles) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Empties the list and reclaims all title-string memory (capacity is
    /// retained for reuse by the next capture).
    pub fn clear(self: *WindowTitles) void {
        _ = self.arena.reset(.retain_capacity);
        self.list.clearRetainingCapacity();
    }

    /// Appends an owned dupe of `title_str`, allocated from the arena.
    pub fn append(self: *WindowTitles, list_allocator: std.mem.Allocator, title_str: []const u8) !void {
        const owned = try self.arena.allocator().dupe(u8, title_str);
        try self.list.append(list_allocator, owned);
    }

    /// Clears the list, then refills it with dupes of `titles`.
    /// Partial failures leave the list shorter than `titles` rather than erroring out.
    pub fn replaceWith(self: *WindowTitles, list_allocator: std.mem.Allocator, titles: []const []const u8) void {
        self.clear();
        for (titles) |t| self.append(list_allocator, t) catch break;
    }

    pub fn deinit(self: *WindowTitles, list_allocator: std.mem.Allocator) void {
        self.list.deinit(list_allocator);
        self.arena.deinit();
    }
};

/// Shared per-window title data embedded by both `BarSnapshot` and
/// `TitleCache` to avoid duplicating fields and deinit logic.
pub const TitleData = struct {
    focused_window: ?u32 = null,
    focused_title: std.ArrayListUnmanaged(u8) = .empty,
    workspace_windows: std.ArrayListUnmanaged(u32) = .empty,
    minimized_windows: std.AutoHashMapUnmanaged(u32, void) = .{},
    window_titles: WindowTitles = .{},
    window_geoms: std.ArrayListUnmanaged(utils.Rect) = .empty,

    pub fn deinit(self: *TitleData, allocator: std.mem.Allocator) void {
        self.focused_title.deinit(allocator);
        self.workspace_windows.deinit(allocator);
        self.minimized_windows.deinit(allocator);
        self.window_titles.deinit(allocator);
        self.window_geoms.deinit(allocator);
    }
};

/// Point-in-time bar state, captured fresh before each draw and diffed
/// against the previous frame's snapshot (see captureStateIntoSlot) to
/// decide which segments actually need repainting.
pub const BarSnapshot = struct {
    title_data: TitleData = .{},
    workspace_has_windows: std.ArrayListUnmanaged(bool) = .empty,
    current_workspace: u8 = 0,
    workspace_count: u32 = 0,
    is_all_view_active: bool = false,
    is_title_invalidated: bool = false,
    is_full_redraw: bool = true, // workspace_count changed or full-redraw forced
    is_workspace_dirty: bool = true, // workspace state changed
    is_title_dirty: bool = true, // title / focus / minimized state changed

    /// True when `window_titles`/`window_geoms` were freshly re-fetched this
    /// frame rather than relayed from the previous snapshot slot. syncTitleCache
    /// uses this to skip re-duping the cache's title strings when nothing changed
    /// : see the ownership-relay comment in captureStateIntoSlot.
    title_list_refreshed: bool = false,

    pub fn deinit(snap: *BarSnapshot, allocator: std.mem.Allocator) void {
        snap.title_data.deinit(allocator);
        snap.workspace_has_windows.deinit(allocator);
    }
};

/// Focus/title/workspace rendering cache; updated after each full draw.
pub const TitleCache = struct {
    title_data: TitleData = .{},
    title_window: ?u32 = null,
    title_x: u16 = 0,
    title_width: u16 = 0,
    is_layout_valid: bool = false,
    is_invalidated: bool = false,

    pub fn deinit(self: *TitleCache, allocator: std.mem.Allocator) void {
        self.title_data.deinit(allocator);
    }
};

// Snapshot capture helpers

/// Builds a replacement list and swaps it into `dst` only on success, so a
/// failed allocation leaves the cache showing stale data rather than empty.
pub fn swapAlloc(comptime T: type, dst: *std.ArrayListUnmanaged(T), alloc: std.mem.Allocator, src: []const T) void {
    if (dst.capacity >= src.len) {
        dst.items.len = 0;
        dst.appendSlice(alloc, src) catch return;
        return;
    }
    var replacement: std.ArrayListUnmanaged(T) = .empty;
    if (replacement.appendSlice(alloc, src)) {
        dst.deinit(alloc);
        dst.* = replacement;
    } else |_| {
        replacement.deinit(alloc);
    }
}

/// Title of the minimized window, used in the single-window title case.
/// Returns "" when no window is minimized or titles were not fetched.
fn minimizedTitleFor(wins: []const u32, minimized: *const std.AutoHashMapUnmanaged(u32, void), titles: []const []const u8) []const u8 {
    return if (wins.len > 0 and minimized.contains(wins[0]) and titles.len > 0) titles[0] else "";
}

pub fn makeTitleSnapshot(
    focused_window: ?u32,
    focused_title: []const u8,
    workspace_windows: []const u32,
    minimized: *const std.AutoHashMapUnmanaged(u32, void),
    titles: []const []const u8,
    geoms: []const utils.Rect,
) title.TitleSnapshot {
    return .{
        .focused_window = focused_window,
        .focused_title = focused_title,
        .minimized_title = minimizedTitleFor(workspace_windows, minimized, titles),
        .current_ws_wins = workspace_windows,
        .minimized_set = minimized,
        .titles = titles,
        .geoms = geoms,
    };
}

/// Returns true when the two minimized sets differ in membership (not just count).
fn hasMinimizedSetChanged(
    a: *const std.AutoHashMapUnmanaged(u32, void),
    b: *const std.AutoHashMapUnmanaged(u32, void),
) bool {
    if (a.count() != b.count()) return true;
    var it = a.keyIterator();
    while (it.next()) |key| if (!b.contains(key.*)) return true;
    return false;
}

/// Collect the minimized window set for the current snapshot.
fn captureMinimizedSet(snap: *BarSnapshot, allocator: std.mem.Allocator) !void {
    snap.title_data.minimized_windows.clearRetainingCapacity();
    try minimize.collectMinimizedIntoSet(&snap.title_data.minimized_windows, allocator);
}

/// Capture the workspace-derived state: count, current workspace, all-view
/// mode, per-workspace occupancy, and the current workspace's window list.
/// OR-accumulates all window masks in a single pass, then derives per-workspace
/// occupancy from the combined bitmask in O(workspace_count).
fn captureWorkspaceState(snap: *BarSnapshot, allocator: std.mem.Allocator) !void {
    // PIPELINE: the model owns the live current-workspace value; the legacy
    // mirror below is kept for workspace_count and updated via
    // workspaces.setCurrent, but the model is authoritative.
    const ws_state = workspaces.getState() orelse return;
    const m = pipeline.model();
    snap.workspace_count = @intCast(ws_state.workspaces.len);
    snap.current_workspace = @intCast(m.current);
    snap.is_all_view_active = m.all_view_active;
    try snap.workspace_has_windows.resize(allocator, snap.workspace_count);
    @memset(snap.workspace_has_windows.items, false);
    snap.title_data.workspace_windows.clearRetainingCapacity();
    const cur_bit: u64 = if (snap.current_workspace < snap.workspace_count)
        tracking.workspaceBit(snap.current_workspace)
    else
        0;
    var combined_mask: u64 = 0;
    for (tracking.allWindows()) |entry| {
        combined_mask |= entry.mask;
        if (cur_bit != 0 and entry.mask & cur_bit != 0)
            try snap.title_data.workspace_windows.append(allocator, entry.win);
    }
    for (0..snap.workspace_count) |i| {
        snap.workspace_has_windows.items[i] = combined_mask & tracking.workspaceBit(@as(u8, @intCast(i))) != 0;
    }
}

/// Capture the focused window and its title. The title is re-fetched from X
/// only when the focused window or the title changed; otherwise the previous
/// frame's copy is reused.
fn captureFocusedTitle(tc: *TitleCache, snap: *BarSnapshot, prev: *BarSnapshot, alloc: std.mem.Allocator) void {
    snap.title_data.focused_window = focus.getFocused();
    snap.is_title_invalidated = tc.is_invalidated;
    tc.is_invalidated = false;

    snap.title_data.focused_title.clearRetainingCapacity();
    if (snap.title_data.focused_window) |fw| {
        if (snap.title_data.focused_window != prev.title_data.focused_window or snap.is_title_invalidated) {
            title.fetchWindowTitleInto(core.getState().conn, fw, &snap.title_data.focused_title, alloc) catch {};
        } else {
            std.mem.swap(std.ArrayListUnmanaged(u8), &snap.title_data.focused_title, &prev.title_data.focused_title);
        }
    }
}

/// (Re)fetch the batched window titles/geometry; or, when nothing changed,
/// relay the previous frame's lists between the two ping-pong slots instead
/// of re-fetching (an O(window count) alloc+free pass saved on redraws where
/// the titles didn't change, e.g. a workspace-indicator repaint). `prev` is
/// not read again this frame, and next frame the roles flip, so ownership
/// relays between the slots with zero allocation traffic until a
/// `title_data_changed` frame refreshes it for real.
fn prefetchWindowTitles(alloc: std.mem.Allocator, snap: *BarSnapshot, prev: *BarSnapshot, title_data_changed: bool) void {
    if (title_data_changed) {
        const focused_idx: ?usize = if (snap.title_data.focused_window) |fw|
            std.mem.indexOfScalar(u32, snap.title_data.workspace_windows.items, fw)
        else
            null;

        // Batch pre-fetch replaces the sequential per-window round-trips:
        // one dupe per title, ~2 round-trips total, zero blocking waits on
        // the draw path itself (see title.batchFetchWindowInfosInto).
        snap.title_data.window_titles.clear();
        snap.title_data.window_geoms.clearRetainingCapacity();
        title.batchFetchWindowInfosInto(
            core.getState().conn,
            snap.title_data.workspace_windows.items,
            focused_idx,
            snap.title_data.focused_title.items,
            &snap.title_data.minimized_windows,
            &snap.title_data.window_titles.list,
            &snap.title_data.window_geoms,
            snap.title_data.window_titles.allocator(),
            alloc,
        );
    } else {
        std.mem.swap(WindowTitles, &snap.title_data.window_titles, &prev.title_data.window_titles);
        std.mem.swap(std.ArrayListUnmanaged(utils.Rect), &snap.title_data.window_geoms, &prev.title_data.window_geoms);
    }
}

/// Captures current WM state into `snap`, diffing against `prev` to set dirty
/// flags. `forced` (caller must read/clear the pending-full-redraw flag)
/// overrides all dirty checks. `prev` is mutable because the "nothing changed"
/// branch swaps ownership of `window_titles`/`window_geoms` between the two
/// ping-pong slots instead of duping them: see `prefetchWindowTitles`.
/// `pending_title_redraw` is the caller's consumed force-title flag (read AND
/// cleared by the caller before calling; passed by value here).
pub fn captureStateIntoSlot(
    alloc: std.mem.Allocator,
    tc: *TitleCache,
    snap: *BarSnapshot,
    prev: *BarSnapshot,
    forced: bool,
    pending_title_redraw: bool,
) !void {
    bench.beginTitleCapture();
    const capture_start_ns: u64 = if (bench.enabled) utils.monotonicNs() else 0;

    try captureMinimizedSet(snap, alloc);
    try captureWorkspaceState(snap, alloc);
    captureFocusedTitle(tc, snap, prev, alloc);

    // Pre-fetch titles so the segmented-title draw path never issues its own
    // X11 calls. Only run when title state changed; clock ticks never reach
    // this function at all, so there's no separate "no-op" case.
    const title_data_changed =
        pending_title_redraw or
        snap.title_data.focused_window != prev.title_data.focused_window or
        snap.is_title_invalidated or
        !std.mem.eql(u32, snap.title_data.workspace_windows.items, prev.title_data.workspace_windows.items) or
        hasMinimizedSetChanged(&snap.title_data.minimized_windows, &prev.title_data.minimized_windows);
    prefetchWindowTitles(alloc, snap, prev, title_data_changed);

    snap.title_list_refreshed = title_data_changed;
    snap.is_full_redraw = forced or (snap.workspace_count != prev.workspace_count);
    snap.is_workspace_dirty = snap.is_full_redraw or
        snap.current_workspace != prev.current_workspace or
        snap.is_all_view_active != prev.is_all_view_active or
        !std.mem.eql(bool, snap.workspace_has_windows.items, prev.workspace_has_windows.items);
    snap.is_title_dirty = title_data_changed or
        prompt.isActive() or
        !std.mem.eql(u8, snap.title_data.focused_title.items, prev.title_data.focused_title.items);

    if (bench.enabled) bench.reportTitleCapture(
        utils.monotonicNs() -| capture_start_ns,
        snap.title_data.workspace_windows.items.len,
    );
}

/// Read-only prediction of whether captureStateIntoSlot would take its
/// expensive path (fresh focused-title fetch plus the batched per-window
/// title/geometry prefetch -- both issue blocking X11 property round trips).
/// Mirrors the `title_data_changed` computation there WITHOUT consuming any
/// flags or touching X11, so grab-held callers can defer the whole capture
/// instead of blocking under xcb_grab_server.
pub fn snapshotNeedsRefetch(pending_title_redraw: bool, prev: *const BarSnapshot, cache_invalidated: bool) bool {
    if (pending_title_redraw) return true;
    if (focus.getFocused() != prev.title_data.focused_window) return true;
    if (cache_invalidated) return true;

    // Rebuild the current workspace's window list on the stack (same source
    // and order as captureWorkspaceState) and compare against last frame's.
    const cur = tracking.getCurrentWorkspace() orelse return false;
    const cur_bit = tracking.workspaceBit(cur);
    var wins: [256]u32 = undefined;
    var n: usize = 0;
    for (tracking.allWindows()) |entry| {
        if (entry.mask & cur_bit == 0) continue;
        if (n == wins.len) return true; // over-capacity: let the real capture handle it
        wins[n] = entry.win;
        n += 1;
    }
    if (!std.mem.eql(u32, wins[0..n], prev.title_data.workspace_windows.items)) return true;

    // Minimized-set equality without allocating: membership of every
    // currently-minimized window plus an equal count covers both directions.
    var min_count: usize = 0;
    for (tracking.allWindows()) |entry| {
        if (!minimize.isMinimized(entry.win)) continue;
        min_count += 1;
        if (!prev.title_data.minimized_windows.contains(entry.win)) return true;
    }
    if (min_count != prev.title_data.minimized_windows.count()) return true;

    return false;
}
