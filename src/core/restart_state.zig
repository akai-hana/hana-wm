//! WM state hand-off across a re-exec (see restart.zig for the trigger/exec
//! machinery).
//!
//! Pure serialize/deserialize of the model to a temp file: no X11 traffic.
//! save() dumps the model; the booting process loadToGlobal()s the file and
//! the adoption path (window.adoptRootWindows) consumes the records while
//! applyModelLevel() restores model-level fields (current/ws params/orders/
//! focused). home_ws and count_minimized are derived and NOT serialized.
//!
//! Wire format: std.json over the shadow records below, which mirror the
//! model types field-for-field. Floats round-trip exactly: std.json prints an
//! f32 as its exact f64 widening and the parse narrows back to the same bits
//! (verified against Zig 0.16's std.json.Stringify). All MAX_WS workspaces
//! are always serialized (array position is the index), so parse-time
//! indexing needs no bounds work and a hand-edited file cannot name a
//! workspace that was never saved.

const std = @import("std");
const model = @import("model");
const debug = @import("debug");
const constants = @import("constants");

const MAX_WS = constants.max_workspaces;

/// Per-window record: identity + mode, matched by XID during adoption.
pub const WindowRecord = struct {
    win: u32,
    mask: model.Mask,
    mode: model.Mode,
};

/// Per-workspace record: layout params + membership lists (ids, not entries).
pub const WsRecord = struct {
    params: model.LayoutParams,
    tiled: []const u32,
    mru: []const u32,
};

/// Top-level serialized state file.
pub const StateFile = struct {
    version: u32 = 1,
    current: u8,
    focused: ?u32,
    all_view_active: bool,
    next_seq: u32,
    workspaces: [MAX_WS]WsRecord,
    windows: []const WindowRecord,
};

/// Parsed restore file, if loadToGlobal succeeded. Module-owned: its arena
/// holds every slice the records reference; freed and replaced by the next
/// loadToGlobal call. Single-threaded (event-loop thread), like the model.
var loaded_parsed: ?std.json.Parsed(StateFile) = null;

/// Default restore path: XDG_RUNTIME_DIR is already per-user, so
/// `$XDG_RUNTIME_DIR/hana-restore.json` needs no uid suffix; the /tmp
/// fallback carries the uid to keep co-located users apart. Caller owns the
/// returned slice.
pub fn defaultStatePath(alloc: std.mem.Allocator) ![]u8 {
    if (std.c.getenv("XDG_RUNTIME_DIR")) |dir| {
        return std.fmt.allocPrint(alloc, "{s}/hana-restore.json", .{std.mem.span(dir)});
    }
    return std.fmt.allocPrint(alloc, "/tmp/hana-restore-{d}.json", .{std.os.linux.getuid()});
}

/// Serializes the live model to `path`. Writes through a temp file + rename
/// so a crash mid-save never leaves a truncated restore file behind (the
/// boot loader tolerates a missing file but warns on a corrupt one). Any
/// error returns to the caller, which ABORTS the re-exec and keeps running.
pub fn save(allocator: std.mem.Allocator, m: *const model.Model, path: []const u8) !void {
    // Windows: flat snapshot of every registered entry (store iterates in
    // sorted-key order). The WindowRecord shape matches the model's Entry
    // fields that survive a re-exec (mask + mode); size_hints and home_ws
    // are rebuilt/derived by registration and transitions.
    const n = m.store.count();
    const windows = try allocator.alloc(WindowRecord, n);
    defer allocator.free(windows);
    for (0..n) |i| {
        const item = m.store.at(i);
        windows[i] = .{ .win = item.key, .mask = item.val.mask, .mode = item.val.mode };
    }

    // Workspaces: every slot, ids copied out of the bounded lists. On a
    // mid-loop dupe failure only the already-filled records are freed.
    var workspaces: [MAX_WS]WsRecord = undefined;
    var ws_filled: usize = 0;
    defer for (workspaces[0..ws_filled]) |r| {
        allocator.free(r.tiled);
        allocator.free(r.mru);
    };
    for (&m.ws, 0..) |*s, i| {
        workspaces[i] = .{
            .params = s.params,
            .tiled = try allocator.dupe(u32, s.tiled_order.constSlice()),
            .mru = try allocator.dupe(u32, s.focus_mru.constSlice()),
        };
        ws_filled = i + 1;
    }

    const state = StateFile{
        .version = 1,
        .current = @intCast(m.current),
        .focused = m.focused,
        .all_view_active = m.all_view_active,
        .next_seq = m.next_seq,
        .workspaces = workspaces,
        .windows = windows,
    };

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try std.json.Stringify.value(state, .{ .whitespace = .indent_2 }, &aw.writer);
    try aw.writer.flush();
    const al = aw.toArrayList();

    const io = std.Options.debug_io;
    const tmp = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp);
    var file = try std.Io.Dir.createFileAbsolute(io, tmp, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, al.items);
    // POSIX rename replaces the name while the fd stays open; the defer's
    // close lands after the rename moved the temp into place.
    try std.Io.Dir.renameAbsolute(tmp, path, io);
}

/// Parses the restore file into the module-global `loaded`. Returns false
/// (after a warn) on any failure so boot proceeds without restore.
pub fn loadToGlobal(allocator: std.mem.Allocator, path: []const u8) !bool {
    const raw = std.Io.Dir.readFileAlloc(
        std.Io.Dir.cwd(),
        std.Options.debug_io,
        path,
        allocator,
        std.Io.Limit.limited(1 << 20),
    ) catch |err| {
        debug.warn("restart_state: no usable restore file ({s}); booting fresh", .{@errorName(err)});
        return false;
    };
    defer allocator.free(raw);

    var parsed = std.json.parseFromSlice(StateFile, allocator, raw, .{}) catch |err| {
        debug.warn("restart_state: restore file unparseable ({s}); booting fresh", .{@errorName(err)});
        return false;
    };
    if (parsed.value.version != 1) {
        debug.warn("restart_state: unsupported restore version {}; booting fresh", .{parsed.value.version});
        parsed.deinit();
        return false;
    }

    if (loaded_parsed) |old| old.deinit();
    loaded_parsed = parsed;
    debug.info("restart_state: loaded session state ({} windows, {d} workspaces)", .{
        loaded_parsed.?.value.windows.len,
        loaded_parsed.?.value.workspaces.len,
    });
    return true;
}

/// The parsed restore file, if loadToGlobal succeeded.
pub fn loaded() ?*const StateFile {
    if (loaded_parsed) |*p| return &p.value;
    return null;
}

/// Restores model-level fields into the model: current/focused/all_view/
/// next_seq, per-ws params, tiled_order and focus_mru — pruned to windows
/// that are actually registered (closed or never adopted ones are dropped).
/// Call AFTER the adoption pass registered the surviving windows.
///
/// count_minimized is intentionally NOT touched here: the adoption pass
/// re-minimizes each restored-minimized window through model.minimize, which
/// maintains the counter and next_seq, so this pass only re-lists tiled
/// membership and copies scalars.
pub fn applyModelLevel(m: *model.Model) void {
    const f = &(loaded_parsed orelse return).value;

    if (f.current < MAX_WS) m.current = f.current;
    m.all_view_active = f.all_view_active;
    if (f.focused) |w| {
        if (m.store.has(w)) m.focused = w;
    }
    if (f.next_seq > m.next_seq) m.next_seq = f.next_seq;

    for (&m.ws, 0..) |*s, i| {
        const r = &f.workspaces[i];
        s.params = r.params;
        s.tiled_order.clear();
        for (r.tiled) |w| {
            if (!m.store.has(w)) continue;
            if (s.tiled_order.len >= model.max_tiled_per_ws) break;
            _ = s.tiled_order.append(w);
        }
        s.focus_mru.clear();
        for (r.mru) |w| {
            if (!m.store.has(w)) continue;
            if (s.focus_mru.len >= model.mru_capacity) break;
            _ = s.focus_mru.append(w);
        }
    }

    // Membership repair: the adoption pass registered every surviving window
    // as a base-tiled member of its home workspace (which also appended it to
    // tiled_order), but the loop above clears and rebuilds tiled_order from a
    // file that may not record everything — a record-less first restore, or a
    // window whose tiled slot was dropped before the file was written. Without
    // a tiled slot the window has no placement and the reconcile parks it
    // offscreen indefinitely. Re-append any base-tiled member that the file
    // did not list (in store order, appended to the list tail).
    for (0..m.store.count()) |i| {
        const it = m.store.at(i);
        const e = it.val;
        if (e.mode != .base) continue;
        if (e.mode.base != .tiled) continue;
        const home = e.home_ws orelse continue;
        if (m.ws[home].tiled_order.indexOfScalar(it.key) != null) continue;
        if (m.ws[home].tiled_order.len >= model.max_tiled_per_ws) continue;
        _ = m.ws[home].tiled_order.append(it.key);
    }
}
