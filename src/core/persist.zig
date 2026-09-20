//! WM state hand-off across a re-exec (see the restart module for the
//! trigger/exec machinery).
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
const core = @import("core");
const debug = @import("debug");
const model = @import("model");
/// Layout registry (build-generated); the active layout is a `u8` index into
/// it (see model.LayoutParams.kind). Empty when the tiling subsystem is
/// absent. Gated on has_tiling so tree variants without tiling compile (the
/// scenario matrix removes the tiling subsystem entirely).
const tiling_mods = @import("plugin").tiling_mods;
/// Shared config-layout-name resolver (registry index or neutral default);
/// see pipeline.defaultIndexForLayoutName.
const pipeline_mod = @import("pipeline");
// Per-feature serialization hooks live on the build-generated `window_modules`
// registry; a tree without a feature has no serializeWindow provider, so the
// loop below no-ops for it.
const window_mods = @import("window_modules").modules;

const MAX_WS = constants.max_workspaces;

/// Wire-format revision of the restore file. Failed or older revisions are
/// rejected in loadToGlobal rather than migrated.
const persist_version: u32 = 4;

/// Cap on the restore file's size. The file is a bounded JSON dump of the
/// model (bounded stores/workspaces), so a file beyond this is junk (or a
/// corrupt/hostile write), not a legitimately huge session.
const max_restore_bytes = 1 << 20;

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
    version: u32 = persist_version,
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
/// One save session's flat records. The owner allocations (dup'ed membership
/// lists and feature blobs) live here so a single deinit releases everything
/// on success and on partial-built error paths alike.
const Snapshot = struct {
    allocator: std.mem.Allocator,
    windows: []WindowRecord,
    workspaces: [MAX_WS]WsRecord,
    ws_filled: usize,

    fn deinit(self: *Snapshot) void {
        // Feature blobs are allocator-owned by contract (each module's
        // serializeWindow allocates them; there is no deinit hook to call).
        for (self.windows) |r| {
            if (r.ext) |blob| self.allocator.free(blob);
        }
        self.allocator.free(self.windows);
        for (self.workspaces[0..self.ws_filled]) |r| {
            self.allocator.free(r.tiled);
            self.allocator.free(r.mru);
        }
    }
};

/// Snapshots the model into ownership-neutral records: every registered
/// window as a flat WindowRecord (store iterates in sorted-key order), plus
/// each workspace's bounded membership lists dup'ed out. The window loop is
/// error-free; a mid-workspace dupe failure is caught by the row-local
/// errdefer (that workspace's tiled slice), and `ws_filled` always counts
/// exactly the workspaces fully built before the failure.
fn saveSnapshot(allocator: std.mem.Allocator, m: *const model.Model) !Snapshot {
    var snap: Snapshot = .{
        .allocator = allocator,
        .windows = try allocator.alloc(WindowRecord, m.store.count()),
        .workspaces = undefined,
        .ws_filled = 0,
    };
    errdefer snap.deinit();

    // The WindowRecord shape matches the model's Entry fields that survive a
    // re-exec (mask + mode); size_hints and home_ws are rebuilt/derived by
    // registration and transitions.
    var widx: usize = 0;
    var it = m.store.iterator();
    while (it.next()) |item| : (widx += 1) {
        // Opaque feature blob: ask each module in registry order whether it
        // owns this window; the first module that returns bytes claims it.
        // The model is handed across the seam AS-IS (a `*const` handle --
        // serialization never mutates, and the contract type is const so this
        // save path can't even @constCast: writing through it is a compile
        // error).
        var blob: ?[]const u8 = null;
        for (window_mods) |mod| {
            if (mod.serializeWindow) |f| {
                if (f(m, item.key, allocator)) |b| {
                    blob = b;
                    break;
                }
            }
        }
        snap.windows[widx] = .{
            .win = item.key,
            .mask = item.val.mask,
            .anchor = item.val.anchor,
            .presence = item.val.presence,
            .covering_ws = item.val.covering_ws,
            .ext = blob,
        };
    }

    // Workspaces: every slot, ids copied out of the bounded lists.
    for (&m.ws, 0..) |*s, i| {
        const tiled = try allocator.dupe(u32, s.tiled_order.constSlice());
        errdefer allocator.free(tiled);
        const mru = try allocator.dupe(u32, s.focus_mru.constSlice());
        snap.workspaces[i] = .{
            .params = s.params,
            .tiled = tiled,
            .mru = mru,
        };
        snap.ws_filled = i + 1;
    }
    return snap;
}

/// Renders the snapshot to JSON bytes (model-level scalars read live from
/// `m`; the durable window/workspace records come from the snapshot).
fn stringifySnapshot(allocator: std.mem.Allocator, m: *const model.Model, snap: *const Snapshot) !std.ArrayList(u8) {
    const state = StateFile{
        .version = persist_version,
        .current = @intCast(m.current.index),
        .focused = m.focused,
        .all_view_active = m.all_view_active,
        .workspaces = snap.workspaces,
        .windows = snap.windows,
    };

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try std.json.Stringify.value(state, .{ .whitespace = .indent_2 }, &aw.writer);
    try aw.writer.flush();
    return aw.toArrayList();
}

/// Writes `bytes` to `path` atomically. Writes through a temp sibling + rename
/// so a crash mid-save never leaves a truncated restore file behind (the boot
/// loader tolerates a missing file but warns on a corrupt one).
fn atomicWrite(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
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
        const attempt = std.Io.Dir.createFileAbsolute(io, tmp, .{ .exclusive = true, .permissions = @enumFromInt(0o600) }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                std.Io.Dir.deleteFileAbsolute(io, tmp) catch {};
                break :blk try std.Io.Dir.createFileAbsolute(io, tmp, .{ .exclusive = true, .permissions = @enumFromInt(0o600) });
            },
            else => return err,
        };
        break :blk attempt;
    };
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
    // POSIX rename replaces the name while the fd stays open; the defer's
    // close lands after the rename moved the temp into place.
    try std.Io.Dir.renameAbsolute(tmp, path, io);
}

/// Serializes the live model to `path`. Any error returns to the caller,
/// which ABORTS the re-exec and keeps running.
pub fn save(allocator: std.mem.Allocator, m: *const model.Model, path: []const u8) !void {
    var snap = try saveSnapshot(allocator, m);
    defer snap.deinit();
    var al = try stringifySnapshot(allocator, m, &snap);
    defer al.deinit(allocator);
    try atomicWrite(allocator, path, al.items);
}

/// Parses the restore file into the module-global `loaded`. Returns false
/// (after a warn) on any failure so boot proceeds without restore.
pub fn loadToGlobal(allocator: std.mem.Allocator, path: []const u8) !bool {
    const raw = std.Io.Dir.readFileAlloc(
        std.Io.Dir.cwd(),
        std.Options.debug_io,
        path,
        allocator,
        std.Io.Limit.limited(max_restore_bytes),
    ) catch |err| {
        debug.warn("persist: no usable restore file ({s}); booting fresh", .{@errorName(err)});
        return false;
    };
    defer allocator.free(raw);

    var parsed = std.json.parseFromSlice(StateFile, allocator, raw, .{}) catch {
        debug.warn("persist: restore file unparseable; booting fresh", .{});
        return false;
    };
    if (parsed.value.version != persist_version) {
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
    const layout_name = core.getState().config.tiling.layout;
    return pipeline_mod.defaultIndexForLayoutName(config_mod.canonicalLayoutName(layout_name));
}

/// Clears `list` and repopulates it from `src`, skipping unregistered windows
/// and honoring `cap`. Shared by the tiled_order and focus_mru restore loops.
fn restoreMembers(list: anytype, src: []const u32, m: *const model.Model, cap: usize) void {
    list.clear();
    for (src) |w| {
        if (!m.store.has(w)) continue;
        if (list.len >= cap) break;
        _ = list.append(w);
    }
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

    if (f.current < MAX_WS) m.current = model.WSId.fromIndex(f.current);
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
        restoreMembers(&s.tiled_order, r.tiled, m, model.max_tiled_per_ws);
        restoreMembers(&s.focus_mru, r.mru, m, model.mru_capacity);
    }

    // Membership repair: the adoption pass registered every surviving window
    // as a base-tiled member of its home workspace (which also appended it to
    // tiled_order), but the loop above clears and rebuilds tiled_order from a
    // file that may not record everything (a record-less first restore, or a
    // window whose tiled slot was dropped before the file was written. Without
    // a tiled slot the window has no placement and the reconcile parks it
    // offscreen indefinitely. Re-append any base-tiled member that the file
    // did not list (in store order, appended to the list tail).
    var it = m.store.iterator();
    while (it.next()) |row| {
        const e = row.val;
        if (e.anchor != .tiled) continue;
        const home = e.home_ws orelse continue;
        if (m.ws[home.index].tiled_order.indexOfScalar(row.key) != null) continue;
        if (m.ws[home.index].tiled_order.len >= model.max_tiled_per_ws) continue;
        _ = m.ws[home.index].tiled_order.append(row.key);
    }
}
