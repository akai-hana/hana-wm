//! Pure serialize/deserialize of WM model state to a temp file for re-exec
//! hand-off; X11-free, arena-based loading, JSON wire format over shadow
//! records with feature-owned extension blobs.

const std = @import("std");
const build_options = @import("build_options");
const config_mod = @import("config");
const core = @import("core");
const log = std.log.scoped(.session);
const model = @import("model");
const snapshot = @import("snapshot");
/// Layout registry (build-generated); the active layout is a `u8` index into
/// it. Empty when the tiling subsystem is absent; has_tiling-gated so tree
/// variants without tiling compile.
const tiling_mods = @import("tiling_contract").tiling_mods;
const contract = @import("tiling_contract");
/// Shared config-layout-name resolver (registry index or neutral default);
/// see pipeline.defaultIndexForLayoutName.
const pipeline_mod = @import("pipeline");
// Per-feature serialization hooks via the build-generated `window_modules` registry.
const window_mods = @import("window_modules").modules;

const MAX_WS = model.max_workspaces;

/// Wire-format revision of the restore file; failed or older revisions are
/// rejected in loadToGlobal, never migrated. Bumped when the durable record
/// shape changes. The per-blob header is versioned SEPARATELY
/// (`ext_format_version`): changing the header does not change the record
/// shape, so a v5 file with a v1 ordinal blob header is still a v5 file.
const handoff_version: u32 = 5;

/// The per-window feature blob header format: every blob is wrapped as
/// `[ext_format_version][name length][claiming module name][payload]` -- the
/// module's stable `contract.WindowModule.name`, not its registry position.
/// Adoption fast-paths on the name and falls back to the magic-byte scan when
/// it no longer resolves (module removed/renamed); the self-identifying tags
/// in each payload keep that fallback unambiguous.
pub const ext_format_version: u8 = 2;

/// Header byte length for a name-stamped blob (version + name length + name);
/// variable-length, so a function of the module name. Shared by save and decodeExt.
fn extHeaderLen(name_len: usize) usize {
    return 2 + name_len;
}

/// One blob's decoded header: the payload to hand a module, plus WHICH module
/// the header claims. `decodeExt` is the ONLY place the on-disk header format
/// is interpreted, so format changes happen there alone.
const ExtHeader = struct {
    /// Bytes after the header; equals `blob` verbatim when unrecognized, so
    /// the payload is always usable.
    payload: []const u8,
    /// Module name from a name-stamped header, or null.
    claimed_name: ?[]const u8,
    /// Registry ordinal from a pre-name header, or null.
    legacy_ordinal: ?usize,
};

/// Decodes a stored ext blob's header. One length check and one version
/// switch, so all three header facts come from a single parse and cannot
/// disagree. A foreign or truncated header yields `payload = blob` -- passed
/// through whole, exactly as an unstamped blob was.
pub fn decodeExt(blob: []const u8) ExtHeader {
    const miss = ExtHeader{ .payload = blob, .claimed_name = null, .legacy_ordinal = null };
    if (blob.len < 2) return miss;
    switch (blob[0]) {
        ext_format_version => {
            const len = extHeaderLen(blob[1]);
            if (blob.len < len) return miss;
            return .{ .payload = blob[len..], .claimed_name = blob[2..len], .legacy_ordinal = null };
        },
        // Legacy ordinal header [version=1][ordinal]: still read so parked
        // windows in a v5 session file are adopted, not silently dropped.
        ext_format_version_ordinal => return .{ .payload = blob[2..], .claimed_name = null, .legacy_ordinal = blob[1] },
        else => return miss,
    }
}

/// Longest module name a blob header can carry in its one length byte.
const max_stamped_name_len: usize = 255;

/// The pre-name blob format: `[version=1][registry ordinal]`. Still read
/// (see decodeExt), never written.
pub const ext_format_version_ordinal: u8 = 1;

/// Cap on the restore file's size. The model is bounded, so a file beyond
/// this is junk (or a corrupt/hostile write), not a huge session.
const max_restore_bytes = 1 << 20;

/// Per-window record: identity + anchor, matched by XID during adoption.
/// `presence` restores visibility (parked/covering windows re-hide via their
/// module's `ext` blob); `ext` is the opaque feature-owned blob. `covering_ws`
/// is the model's core covering intent, persisted on the record independent
/// of module blobs so a minimized-from-fullscreen window (whose fullscreen
/// blob is deliberately absent) restores its covering identity without any
/// optional subsystem.
pub const WindowRecord = struct {
    win: u32,
    mask: model.Mask,
    anchor: model.BaseMode,
    presence: model.Presence = .present,
    covering_ws: ?model.WSId = null,
    ext: ?[]const u8 = null,
};

/// Per-workspace record: layout params + membership lists (ids, not entries).
const WsRecord = struct {
    params: model.LayoutParams,
    tiled: []const u32,
    mru: []const u32,
};

/// Top-level serialized state file.
const StateFile = struct {
    version: u32 = handoff_version,
    current: u8,
    focused: ?u32,
    all_view_active: bool,
    workspaces: [MAX_WS]WsRecord,
    windows: []const WindowRecord,
};

/// Parsed restore file, if loadToGlobal succeeded. Its arena holds every
/// slice the records reference; freed and replaced by the next loadToGlobal.
/// Single-threaded (event-loop thread), like the model.
var loaded_parsed: ?std.json.Parsed(StateFile) = null;

/// Default restore path; the shared XDG-/tmp-uid policy lives in
/// snapshot.runtimeFile. Caller owns the returned slice.
pub fn defaultStatePath(alloc: std.mem.Allocator) ![]u8 {
    return snapshot.runtimeFile(alloc, "hana-restore", ".json");
}

/// Cold-boot housekeeping for this module's file. Adoption is gated on
/// `restart.restore_env` (set only by `execNext`, only alongside a file it
/// just wrote), so without that gate a restore file is a crash leftover.
/// Whether its XIDs still name the same windows is unknowable (the X server
/// may have recycled them), so no boot ever adopts it -- discard, once.
pub fn discardOrphan(alloc: std.mem.Allocator) void {
    const path = defaultStatePath(alloc) catch |err| {
        log.warn("handoff: no restore path ({s}); skipping orphan cleanup", .{@errorName(err)});
        return;
    };
    defer alloc.free(path);
    std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            log.warn("handoff: could not remove leftover restore file ({s}): {s}", .{ path, @errorName(err) });
            return;
        },
    };
    log.info("handoff: discarded restore file left by a session that did not exit cleanly ({s})", .{path});
}

/// One save session's flat records; owner allocations (dup'ed lists, blobs)
/// live here so one deinit covers success and partial-built error paths.
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

    // WindowRecord carries only the Entry fields that survive a re-exec
    // (mask + mode); size_hints and home_ws are rebuilt by registration.
    var widx: usize = 0;
    var it = m.store.iterator();
    while (it.next()) |item| : (widx += 1) {
        // Opaque feature blob: first module (registry order) returning bytes
        // claims the window; the blob is stamped with its stable name so
        // adoption can fast-path (deleted/renamed modules fall back to the
        // magic-byte scan). The model crosses the hook AS-IS: a `*const`
        // handle, and the contract type is const so writing is a compile error.
        var blob: ?[]const u8 = null;
        for (window_mods, 0..) |mod, idx| {
            if (mod.serializeWindow) |f| {
                if (f(m, item.key, allocator)) |body| {
                    // own_body tracks who frees `body`: the over-long-name
                    // branch transfers ownership into `blob`; the normal branch
                    // copies into `wrapped` and still frees on scope exit.
                    // Without the flag the over-long branch's deferred free
                    // fired on break, leaving snap.windows[].ext dangling.
                    var own_body = true;
                    defer if (own_body) allocator.free(body);
                    const mod_name = mod.name;
                    if (mod_name.len == 0) {
                        // Cannot happen (the generated registry rejects an
                        // empty name at compile time); reported rather than
                        // asserted because an unstamped blob still degrades
                        // correctly to the magic-byte scan -- just slower.
                        log.warn(
                            "handoff: module #{} serializes windows but has no " ++
                                "name; stamping an unnamed header (adoption will " ++
                                "fall back to the magic-byte scan)",
                            .{idx},
                        );
                    }
                    if (mod_name.len > max_stamped_name_len) {
                        log.warn(
                            "handoff: module name '{s}' is {} bytes, over the " ++
                                "{} byte stamp limit; not stamping this window",
                            .{ mod_name, mod_name.len, max_stamped_name_len },
                        );
                        blob = body;
                        own_body = false;
                        break;
                    }
                    const header_len = extHeaderLen(mod_name.len);
                    const wrapped = try allocator.alloc(u8, header_len + body.len);
                    errdefer allocator.free(wrapped);
                    wrapped[0] = ext_format_version;
                    wrapped[1] = @intCast(mod_name.len);
                    @memcpy(wrapped[2..header_len], mod_name);
                    @memcpy(wrapped[header_len..], body);
                    blob = wrapped;
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
    // The loader reads the whole fixed-size workspace array, so a short fill
    // would be read back as a truncated session; the loop can only fail, so a
    // short fill is a bug -- say so.
    std.debug.assert(snap.ws_filled == MAX_WS);
    return snap;
}

/// Writes `bytes` to `path` atomically. Writes through a temp sibling + rename
/// so a crash mid-save never leaves a truncated restore file behind (the boot
/// loader tolerates a missing file but warns on a corrupt one).
fn atomicWrite(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    const io = std.Options.debug_io;
    // Pid-qualified: two instances racing one temp path could have the
    // loser's unlink delete the winner's in-flight file.
    const tmp = try std.fmt.allocPrint(allocator, "{s}.{d}.tmp", .{ path, std.os.linux.getpid() });
    defer allocator.free(tmp);
    // Exclusive, no-follow create: a planted symlink/hardlink at the temp
    // path would otherwise redirect the write to an attacker-chosen file.
    // O_EXCL fails with PathAlreadyExists if anything occupies the name; a
    // stale temp from a crashed run is the one legitimate occupant -- remove
    // it and retry once.
    const file = blk: {
        const attempt = createExclusive(io, tmp) catch |err| switch (err) {
            error.PathAlreadyExists => {
                std.Io.Dir.deleteFileAbsolute(io, tmp) catch {};
                break :blk try createExclusive(io, tmp);
            },
            else => return err,
        };
        break :blk attempt;
    };
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
    // Flush BEFORE the rename. Rename is atomic w.r.t. the NAME, not the
    // DATA: without the sync, a crash right after rename can leave the new
    // name pointing at blocks never on disk -- the truncated-file outcome the
    // temp-file dance exists to prevent. The page cache usually surviving is
    // not a durability property.
    try file.sync(io);
    // POSIX rename replaces the name while the fd stays open; the defer's close lands after.
    try std.Io.Dir.renameAbsolute(tmp, path, io);
}

/// Exclusive, owner-only create (no-follow): see atomicWrite's comment.
fn createExclusive(io: std.Io, path: []const u8) !std.Io.File {
    return std.Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true, .permissions = @enumFromInt(snapshot.restricted_file_mode) });
}

/// Serializes the live model to `path`. Any error returns to the caller,
/// which ABORTS the re-exec and keeps running.
pub fn save(allocator: std.mem.Allocator, m: *const model.Model, path: []const u8) !void {
    var snap = try saveSnapshot(allocator, m);
    defer snap.deinit();
    // Model-level scalars read live from `m`; durable records come from the
    // snapshot. Two shapes on purpose: `Snapshot` OWNS duped records + blobs
    // (partial-fill deinit), `StateFile` is the pure wire value -- merging
    // them would hang an Allocator off the JSON type or free arena memory.
    const state = StateFile{
        .version = handoff_version,
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
    try atomicWrite(allocator, path, aw.written());
}

/// Parses the restore file into the module-global `loaded`. Returns false
/// (after a warn) on any failure so boot proceeds without restore.
pub fn loadToGlobal(allocator: std.mem.Allocator, path: []const u8) bool {
    const raw = std.Io.Dir.readFileAlloc(
        std.Io.Dir.cwd(),
        std.Options.debug_io,
        path,
        allocator,
        std.Io.Limit.limited(max_restore_bytes),
    ) catch |err| {
        log.warn("handoff: no usable restore file ({s}); booting fresh", .{@errorName(err)});
        return false;
    };
    defer allocator.free(raw);

    var parsed = std.json.parseFromSlice(StateFile, allocator, raw, .{}) catch {
        log.warn("handoff: restore file unparseable; booting fresh", .{});
        return false;
    };
    if (parsed.value.version != handoff_version) {
        const ver = parsed.value.version;
        parsed.deinit();
        log.warn("handoff: unsupported restore version {}; booting fresh", .{ver});
        return false;
    }

    if (loaded_parsed) |old| old.deinit();
    const p = parsed.value;
    loaded_parsed = parsed;
    log.info("handoff: loaded session state ({} windows, {d} workspaces)", .{
        p.windows.len,
        p.workspaces.len,
    });
    return true;
}

/// The parsed restore file, if loadToGlobal succeeded.
pub fn loaded() ?*const StateFile {
    if (loaded_parsed) |*p| return &p.value;
    return null;
}

/// The degraded-restore fallback layout kind: the active config's default
/// layout name, re-canonicalized for defense, resolved against the registry
/// by name, else index 0 (contract.default_kind's neutral last resort). Runs
/// only on the removed-layout path in applyModelLevel.
fn resumableDefaultKind() u8 {
    if (comptime !build_options.has_tiling) return contract.default_kind;
    const layout_name = core.getState().config.tiling.defaultLayout();
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

/// Restores model-level fields: current/focused/all_view, per-workspace
/// params, tiled_order and focus_mru (pruned to registered windows). Call
/// AFTER the adoption phase registered the surviving windows. No feature
/// counters live here -- extensions own their state (minimize keeps its
/// sequence internally); this phase only re-lists membership and scalars.
pub fn applyModelLevel(m: *model.Model) void {
    const f = loaded() orelse return;

    // Restore the model-authoritative covering intent (presence + covering_ws)
    // from the window records. Fullscreen needs no module blob (its state IS
    // the model intent), so this phase is the fullscreen restore path; a
    // `.parked` record still carrying covering_ws keeps presence intact while
    // restoring its capture target.
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
        // resolves (module removed between runs) falls back to the config
        // default kind, loudly. variant_idx is validated for the same reason:
        // a bare ordinal whose variant list shrank would otherwise index past
        // the module's own table -- clamp to the reported count and say so.
        const restored = @import("tiling_contract").moduleOf(s.params.kind);
        if (restored) |l| {
            const vc = l.variant_count;
            if (s.params.variant_idx >= vc) {
                log.warn(
                    "handoff: clamping restored variant_idx {} to {} (layout " ++
                        "'{}' exposes {} variant(s))",
                    .{ s.params.variant_idx, vc -| 1, s.params.kind, vc },
                );
                s.params.variant_idx = vc -| 1;
            }
        }
        if (restored == null and tiling_mods.len > 0) {
            const fallback = resumableDefaultKind();
            log.warn(
                "handoff: restoring persisted layout kind {} which no " ++
                    "longer resolves ({} registered); using default kind {}",
                .{ s.params.kind, tiling_mods.len, fallback },
            );
            s.params.kind = fallback;
            s.params.variant_idx = 0;
        }
        restoreMembers(&s.tiled_order, r.tiled, m, model.max_tiled_per_ws);
        restoreMembers(&s.focus_mru, r.mru, m, model.mru_capacity);
    }

    // Membership repair: the loop above rebuilds tiled_order from a file that
    // may not record every window (a record-less first restore, or a slot
    // dropped before the file was written). Without a tiled slot a window has
    // no placement and the reconcile parks it offscreen indefinitely, so
    // re-append any base-tiled member the file did not list (store order,
    // list tail).
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
