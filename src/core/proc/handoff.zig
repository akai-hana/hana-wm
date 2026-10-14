//! Pure serialize/deserialize of WM model state to a temp file for re-exec
//! hand-off; X11-free, arena-based loading, JSON wire format over shadow
//! records with feature-owned extension blobs.

const std = @import("std");
const config_mod = @import("config");
const constants = @import("constants");
const core = @import("core");
const log = @import("log");
const model = @import("model");
const paths = @import("paths");
/// Layout registry (build-generated); the active layout is a `u8` index into
/// it (see model.LayoutParams.kind). Empty when the tiling subsystem is
/// absent. Gated on has_tiling so tree variants without tiling compile (the
/// scenario matrix removes the tiling subsystem entirely).
const tiling_mods = @import("contract").tiling_mods;
/// Shared config-layout-name resolver (registry index or neutral default);
/// see pipeline.defaultIndexForLayoutName.
const pipeline_mod = @import("pipeline");
// Per-feature serialization hooks via the build-generated `window_modules`
// registry (a tree without a feature has no serializeWindow provider).
const window_mods = @import("window_modules").modules;

const MAX_WS = constants.max_workspaces;

/// Wire-format revision of the restore file. Failed or older revisions are
/// rejected in loadToGlobal rather than migrated. Bumped whenever the durable
/// record shape changes; v5 adds the per-blob header, so only v5+ restore
/// files are accepted. The header's own format is versioned SEPARATELY
/// (`ext_format_version`), because changing it does not change the durable
/// record shape: a v5 file stamped with a v1 (ordinal) blob header is still a
/// v5 file and is still read, so this constant did NOT move.
const handoff_version: u32 = 5;

/// The per-window feature blob header format. Every blob this module stores is
/// wrapped as `[ext_format_version][name length][claiming module name][payload]`
/// -- the name is the module's stable `contract.WindowModule.name`, not its
/// position in the build-generated `window_modules` registry. Adoption
/// (admission.applyRestoredRecord) fast-paths on the name and falls back to the
/// magic-byte scan when the name no longer resolves (module removed or
/// renamed) — the
/// self-identifying format tags each module embeds in its payload keep the
/// fallback unambiguous.
pub const ext_format_version: u8 = 2;

/// Header byte length for a name-stamped blob: version + name length + the
/// name itself. The name is variable-length, so this is a function of the
/// module name rather than a constant -- a fixed 2-byte ordinal header is
/// what [3.11] removed. Shared by the writer (save path) and `decodeExt`.
fn extHeaderLen(name_len: usize) usize {
    return 2 + name_len;
}

/// One blob's decoded header: the payload to hand a module, plus WHICH module
/// the header claims, if any. (9.10)
///
/// `decodeExt` below is the ONLY place the on-disk header format is
/// interpreted, so a format change is a change there rather than at every
/// reader.
const ExtHeader = struct {
    /// Bytes after the header. Equals `blob` verbatim when the header is not
    /// recognized, so the payload is always usable.
    payload: []const u8,
    /// Module name from a name-stamped header, or null.
    claimed_name: ?[]const u8,
    /// Registry ordinal from a pre-name header, or null.
    legacy_ordinal: ?usize,
};

/// Decodes a stored ext blob's header. (9.10)
///
/// `blob` is the raw stored bytes: one length check and one version switch,
/// so all three header facts come from a single parse and cannot disagree
/// with each other the way independent re-derivations can. A foreign or
/// truncated header yields `payload = blob` -- passed through WHOLE, exactly
/// as an unstamped blob was.
pub fn decodeExt(blob: []const u8) ExtHeader {
    const miss = ExtHeader{ .payload = blob, .claimed_name = null, .legacy_ordinal = null };
    if (blob.len < 2) return miss;
    switch (blob[0]) {
        ext_format_version => {
            const len = extHeaderLen(blob[1]);
            if (blob.len < len) return miss;
            return .{ .payload = blob[len..], .claimed_name = blob[2..len], .legacy_ordinal = null };
        },
        // Legacy ordinal header: [version=1][ordinal]. Still read, so a
        // session saved by the previous format is adopted rather than
        // silently dropped.
        ext_format_version_ordinal => return .{ .payload = blob[2..], .claimed_name = null, .legacy_ordinal = blob[1] },
        else => return miss,
    }
}

/// Longest module name a blob header can carry in its one length byte.
const max_stamped_name_len: usize = 255;

/// The pre-name blob format: `[version=1][registry ordinal]`. Still READ (see
/// `decodeExt`) so a v5 session file keeps its parked windows, never written.
pub const ext_format_version_ordinal: u8 = 1;

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

/// Parsed restore file, if loadToGlobal succeeded. Module-owned: its arena
/// holds every slice the records reference; freed and replaced by the next
/// loadToGlobal call. Single-threaded (event-loop thread), like the model.
var loaded_parsed: ?std.json.Parsed(StateFile) = null;

/// Default restore path; the shared XDG-/tmp-uid policy lives in
/// paths.runtimeFile. Caller owns the returned slice.
pub fn defaultStatePath(alloc: std.mem.Allocator) ![]u8 {
    return paths.runtimeFile(alloc, "hana-restore", ".json");
}

/// Cold-boot housekeeping for the file this module owns. Adoption is gated on
/// `restart.restore_env` (set only by `execNext`, only alongside a file it
/// just wrote), so when that gate is absent a restore file at the default path
/// is a leftover of a session that crashed before its graceful-exit delete.
/// Whether its XIDs still name the same windows is unknowable here (the X
/// server may have restarted since and recycled them), so no boot ever adopts
/// it -- discard rather than let a dead session's record linger (and report
/// the leftover exactly once, rather than on every subsequent boot).
pub fn discardOrphan(alloc: std.mem.Allocator) void {
    const path = defaultStatePath(alloc) catch |err| {
        log.warn("handoff: no restore path ({s}); skipping orphan cleanup", .{@errorName(err)});
        return;
    };
    defer alloc.free(path);
    std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, path) catch |err| switch (err) {
        // The normal cold-boot outcome: this session never re-exec'd, so
        // there is no record to discard and nothing to report.
        error.FileNotFound => return,
        else => {
            log.warn("handoff: could not remove leftover restore file ({s}): {s}", .{ path, @errorName(err) });
            return;
        },
    };
    log.info("handoff: discarded restore file left by a session that did not exit cleanly ({s})", .{path});
}

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
        // owns this window; the first module that returns bytes claims it, and
        // the blob is stamped with the module's stable name so adoption can
        // fast-path on it (a deleted or renamed module still falls back to the
        // magic-byte scan). The model is handed across
        // the seam AS-IS (a `*const` handle -- serialization never mutates, and
        // the contract type is const so this save path can't even @constCast:
        // writing through it is a compile error).
        var blob: ?[]const u8 = null;
        for (window_mods, 0..) |mod, idx| {
            if (mod.serializeWindow) |f| {
                if (f(m, item.key, allocator)) |body| {
                    // own_body tracks whether the arms of this scope are still
                    // responsible for freeing `body`. The over-long-name branch
                    // transfers that ownership into `blob` (the snapshot owns
                    // it from there); the normal branch copies body into
                    // `wrapped` and so still frees it on scope exit. Without
                    // the transfer flag, the over-long branch's deferred free
                    // fired on break and left snap.windows[].ext dangling.
                    var own_body = true;
                    defer if (own_body) allocator.free(body);
                    const mod_name = mod.name;
                    if (mod_name.len == 0) {
                        // Cannot happen: the generated window registry rejects
                        // a serializing module with an empty name at compile
                        // time. Reported rather than asserted because a blob
                        // stamped with nothing degrades to the magic-byte scan
                        // and is still correct -- just slower.
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
    // The loader reads the whole fixed-size workspace array, so a snapshot that
    // stopped early would be read back as a truncated session. The loop above
    // can only fail, never break early, so a short fill is a bug -- say so.
    std.debug.assert(snap.ws_filled == MAX_WS);
    return snap;
}

/// Writes `bytes` to `path` atomically. Writes through a temp sibling + rename
/// so a crash mid-save never leaves a truncated restore file behind (the boot
/// loader tolerates a missing file but warns on a corrupt one).
fn atomicWrite(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    const io = std.Options.debug_io;
    // Pid-qualified: two hana instances restoring the same session would
    // otherwise race on one temp path, and the loser's unlink could delete
    // the winner's in-flight file.
    const tmp = try std.fmt.allocPrint(allocator, "{s}.{d}.tmp", .{ path, std.os.linux.getpid() });
    defer allocator.free(tmp);
    // Exclusive, no-follow create: a pre-existing symlink or hardlink at the
    // temp path would otherwise be followed and redirect the write to an
    // attacker-chosen file. O_EXCL makes the open fail with PathAlreadyExists
    // if anything (symlink, hardlink, or regular file) already occupies the
    // name, so we never write through a planted entry. A stale temp left by a
    // crashed run is the one legitimate occupant; remove it and retry once.
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
    // Flush BEFORE the rename. Rename is atomic with respect to the NAME, not
    // the DATA: without the sync, a crash right after the rename can leave the
    // new name pointing at blocks that never reached disk, so the boot-time
    // loader can read a truncated file -- the exact outcome the temp-file dance
    // above exists to prevent. Skipping this only "worked" because the page
    // cache usually survives; that is not a durability property.
    try file.sync(io);
    // POSIX rename replaces the name while the fd stays open; the defer's
    // close lands after the rename moved the temp into place.
    try std.Io.Dir.renameAbsolute(tmp, path, io);
}

/// Exclusive, owner-only create (no-follow): see atomicWrite's comment.
fn createExclusive(io: std.Io, path: []const u8) !std.Io.File {
    return std.Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true, .permissions = @enumFromInt(paths.restricted_file_mode) });
}

/// Serializes the live model to `path`. Any error returns to the caller,
/// which ABORTS the re-exec and keeps running.
pub fn save(allocator: std.mem.Allocator, m: *const model.Model, path: []const u8) !void {
    var snap = try saveSnapshot(allocator, m);
    defer snap.deinit();
    // Model-level scalars read live from `m`; the durable records come from
    // the snapshot. The two shapes stay two types on purpose (the judgment
    // behind this seam's collapse): `Snapshot` OWNS the duped records + blobs
    // (allocator, partial-fill deinit), `StateFile` is the pure wire value --
    // merging them would hang an Allocator off the JSON type or hand the
    // parsed value an ownership-ful deinit that would free arena memory.
    // `stringifySnapshot` (single caller) folded here with that in mind.
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
/// layout name (canonical at parse time, re-canonicalized here for defense),
/// resolved against the registry by name, else index 0 -- the same neutral
/// last resort as contract.default_kind. Runs only on the removed-layout path
/// (applyModelLevel) where core is already initialized and config is live.
fn resumableDefaultKind() u8 {
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

/// Restores model-level fields into the model: current/focused/all_view,
/// per-ws params, tiled_order and focus_mru (pruned to windows that are
/// actually registered (closed or never adopted ones are dropped). Call AFTER
/// the adoption phase registered the surviving windows.
///
/// No feature counters live here anymore: extensions own all of their state
/// (minimize maintains its sequence internally), so this phase only re-lists
/// tiled membership and copies scalars.
pub fn applyModelLevel(m: *model.Model) void {
    const f = loaded() orelse return;

    // Restore the model-authoritative covering intent (presence + covering_ws)
    // from the window records. Fullscreen needs no module blob (its state IS
    // the model intent), so this phase is the fullscreen restore path. A
    // `.parked` record that still carries covering_ws (minimized-from-fullscreen)
    // keeps presence intact while restoring the capture target.
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
        // variant_idx is validated here for the same reason `kind` is: it is
        // persisted as a bare ordinal, so a variant that no longer exists
        // (a module trimmed its variant list between runs) would otherwise
        // index past the end of the module's own table. Clamp to the reported
        // count and say so, rather than reading out of bounds.
        const restored = @import("contract").moduleOf(s.params.kind);
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

    // Membership repair: the adoption phase registered every surviving window
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
