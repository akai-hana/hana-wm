//! WM state hand-off across a re-exec (see restart.zig for the trigger/exec
//! machinery).
//!
//! Pure serialize/deserialize of the model to a temp file: no X11 traffic.
//! save() dumps the model; the booting process loadToGlobal()s the file and
//! the adoption path (window.adoptRootWindows) consumes the records while
//! applyModelLevel() restores model-level fields (current/ws params/orders/
//! focused). home_ws and count_minimized are derived and NOT serialized.
//!
//! Seam: each WindowRecord carries `presence` (model.Presence) and
//! an opaque `ext` blob. Only `presence` and the identity/mode survive in the
//! model; `ext` is feature-owned bytes carried verbatim and handed back to
//! the owning module (via the window_modules registry) during adoption/wire
//! deserialize. The raw bytes are serialized with std.json as a []const u8
//! (an array of numbers; ~8 bytes/window, deterministic round-trip).
//!
//! Wire format: std.json over the shadow records below, which mirror the
//! model types field-for-field. Floats round-trip exactly: std.json prints an
//! f32 as its exact f64 widening and the parse narrows back to the same bits
//! (verified against Zig 0.16's std.json.Stringify). All MAX_WS workspaces
//! are always serialized (array position is the index), so parse-time
//! indexing needs no bounds work and a hand-edited file cannot name a
//! workspace that was never saved.

const std = @import("std");
const build_options = @import("build_options");
const config_mod = @import("config");
const constants = @import("constants");
const debug = @import("debug");
const model = @import("model");
/// Layout registry (build-generated); the active layout is a `u8` index into
/// it (see model.LayoutParams.kind). Empty when the tiling subsystem is
/// absent. Gated on has_tiling so tree variants without tiling compile (the
/// scenario matrix removes src/tiling entirely).
const tiling_mods = @import("plugin").tiling_mods;
const tiling = if (build_options.has_tiling) @import("tiling") else struct {};
// Per-feature serialization hooks live on the build-generated `window_modules`
// registry; a tree without a feature has no serializeWindow provider, so the
// loop below no-ops for it.
const window_mods = @import("window_modules").modules;

const MAX_WS = constants.max_workspaces;

/// Per-window record: identity + anchor, matched by XID during adoption.
/// `presence` restores visibility semantics across the re-exec (parked /
/// covering windows are re-hidden by the adopting module via their `ext`
/// blob); `ext` is the opaque feature-owned serialized blob (null when no
/// feature claimed it). `covering_ws` is the model's core covering intent,
/// persisted directly on the record (independent of module blobs) so a
/// window minimized-from-fullscreen — whose fullscreen blob is deliberately
/// absent (parked ⇒ minimize owns the slot) — still restores its covering
/// identity across the re-exec without needing any optional subsystem.
pub const WindowRecord = struct {
    win: u32,
    mask: model.Mask,
    anchor: model.BaseMode,
    presence: model.Presence = .present,
    covering_ws: ?model.WSId = null,
    ext: ?[]const u8 = null,
};

/// Per-workspace record: layout params + membership lists (ids, not entries).
pub const WsRecord = struct {
    params: model.LayoutParams,
    tiled: []const u32,
    mru: []const u32,
};

/// Top-level serialized state file.
pub const StateFile = struct {
    version: u32 = 4,
    current: u8,
    focused: ?u32,
    all_view_active: bool,
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
        // Opaque feature blob: ask each module in registry order whether it
        // owns this window; the first module that returns bytes claims it.
        // `blob` memory is allocator-owned and freed by the caller (below).
        // The model is handed across the seam as *anyopaque so the module
        // layer can read presence while serializing (parked-only claims).
        var blob: ?[]const u8 = null;
        for (window_mods) |mod| {
            if (mod.serializeWindow) |f| {
                if (f(@constCast(m), item.key, allocator)) |b| {
                    blob = b;
                    break;
                }
            }
        }
        windows[i] = .{
            .win = item.key,
            .mask = item.val.mask,
            .anchor = item.val.anchor,
            .presence = item.val.presence,
            .covering_ws = item.val.covering_ws,
            .ext = blob,
        };
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
        .version = 4,
        .current = @intCast(m.current),
        .focused = m.focused,
        .all_view_active = m.all_view_active,
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
    // Exclusive, no-follow create: a pre-existing symlink or hardlink at the
    // temp path would otherwise be followed and redirect the write to an
    // attacker-chosen file. O_EXCL makes the open fail with PathAlreadyExists
    // if anything (symlink, hardlink, or regular file) already occupies the
    // name, so we never write through a planted entry. A stale temp left by a
    // crashed run is the one legitimate occupant; remove it and retry once.
    const file = blk: {
        const attempt = createTmpExclusive(io, tmp) catch |err| switch (err) {
            error.PathAlreadyExists => {
                std.Io.Dir.deleteFileAbsolute(io, tmp) catch {};
                break :blk try createTmpExclusive(io, tmp);
            },
            else => return err,
        };
        break :blk attempt;
    };
    defer file.close(io);
    try file.writeStreamingAll(io, al.items);
    // fsync the temp file before renaming it into place so its content is
    // flushed to disk. Otherwise the directory entry can point at unflushed
    // page-cache data, and a power-loss can leave a truncated restore file.
    try file.sync(io);
    // POSIX rename replaces the name while the fd stays open; the defer's
    // close lands after the rename moved the temp into place.
    try std.Io.Dir.renameAbsolute(tmp, path, io);
}

/// Opens `path` for writing, creating it exclusively so a pre-existing
/// symlink or hardlink at the name is rejected (O_EXCL) rather than followed.
fn createTmpExclusive(io: std.Io, path: []const u8) std.Io.File.OpenError!std.Io.File {
    return std.Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true });
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
        debug.warn("persist: no usable restore file ({s}); booting fresh", .{@errorName(err)});
        return false;
    };
    defer allocator.free(raw);

    var parsed = std.json.parseFromSlice(StateFile, allocator, raw, .{}) catch {
        debug.warn("persist: restore file unparseable; booting fresh", .{});
        return false;
    };
    if (parsed.value.version != 4) {
        const ver = parsed.value.version;
        parsed.deinit();
        debug.warn("persist: unsupported restore version {}; booting fresh", .{ver});
        return false;
    }

    if (loaded_parsed) |old| old.deinit();
    loaded_parsed = parsed;
    debug.info("persist: loaded session state ({} windows, {d} workspaces)", .{
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

/// The degraded-restore fallback layout kind: the active config's default
/// layout name (canonical at parse time, re-canonicalized here for defense),
/// resolved against the registry by name, else index 0 -- the same neutral
/// last resort as tiling.defaultKind. Runs only on the removed-layout path
/// (applyModelLevel) where core is already initialized and config is live.
fn resumableDefaultKind() u8 {
    if (!build_options.has_tiling) return 0;
    const layout_name = @import("core").getState().config.tiling.layout;
    return @intCast(tiling.layoutByName(config_mod.canonicalLayoutName(layout_name)) orelse 0);
}

/// Restores model-level fields into the model: current/focused/all_view,
/// per-ws params, tiled_order and focus_mru (pruned to windows that are
/// actually registered (closed or never adopted ones are dropped). Call AFTER
/// the adoption pass registered the surviving windows.
///
/// No feature counters live here anymore: extensions own all of their state
/// (minimize maintains its sequence internally), so this pass only re-lists
/// tiled membership and copies scalars.
pub fn applyModelLevel(m: *model.Model) void {
    const f = loaded() orelse return;

    // Restore the model-authoritative covering intent (presence + covering_ws)
    // from the window records, independent of module blobs. A `.parked` record
    // that still carries covering_ws (minimized-from-fullscreen) keeps presence
    // intact while restoring the capture target. Idempotent with what the
    // fullscreen module's deserializeWindow already applied.
    for (f.windows) |r| {
        if (r.covering_ws == null and r.presence != .covering) continue;
        const e = m.store.getPtr(r.win) orelse continue;
        if (r.presence == .covering) e.presence = .covering;
        if (r.covering_ws) |cws| e.covering_ws = cws;
    }

    if (f.current < MAX_WS) m.current = f.current;
    m.all_view_active = f.all_view_active;
    if (f.focused) |w| {
        if (m.store.has(w)) m.focused = w;
    }

    for (&m.ws, 0..) |*s, i| {
        const r = &f.workspaces[i];
        s.params = r.params;
        // Registry-driven layout kind: a persisted index that no longer
        // resolves (a layout module was removed between runs) falls back to the
        // config default kind (index 0 as the neutral last resort) instead of
        // leaving an unresolvable dispatch id. Loud, so the degradation is never
        // silent.
        if (s.params.kind >= tiling_mods.len and tiling_mods.len > 0) {
            const fallback = resumableDefaultKind();
            debug.warn(
                "persist: restoring persisted layout kind {} which no " ++
                    "longer resolves ({} registered); using default kind {}",
                .{ s.params.kind, tiling_mods.len, fallback },
            );
            s.params.kind = fallback;
            s.params.variant_idx = 0;
        }
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
    // file that may not record everything (a record-less first restore, or a
    // window whose tiled slot was dropped before the file was written. Without
    // a tiled slot the window has no placement and the reconcile parks it
    // offscreen indefinitely. Re-append any base-tiled member that the file
    // did not list (in store order, appended to the list tail).
    for (0..m.store.count()) |i| {
        const it = m.store.at(i);
        const e = it.val;
        if (e.anchor != .tiled) continue;
        const home = e.home_ws orelse continue;
        if (m.ws[home].tiled_order.indexOfScalar(it.key) != null) continue;
        if (m.ws[home].tiled_order.len >= model.max_tiled_per_ws) continue;
        _ = m.ws[home].tiled_order.append(it.key);
    }
}
