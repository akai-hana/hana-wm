//! Native PulseAudio backend for the volume segment, via runtime `dlopen`
//! of `libpulse.so.0` -- no headers, no link-time dependency, no subprocess.
//!
//! Every commit and read is an in-process call into a threaded mainloop
//! that talks the native protocol straight to the PulseAudio/PipeWire
//! daemon. Commits are single socket round-trips, which is what makes
//! per-event, un-throttled volume scrolls/drags possible.
//!
//! Links NOTHING at build time: symbols resolved at runtime with
//! `std.DynLib`. Without `libpulse.so.0` the attach fails cleanly and the
//! volume segment falls back to its `pactl`/`amixer` path.
//!
//! ABI discipline: instead of linking the pulse headers, the handful of
//! structs we touch are read as raw bytes. Layouts are stable across the
//! pulse 1.x-16.x era, but every field is guard-checked at runtime; a failed
//! guard abandons the backend. `pa_server_info` has a version-dependent
//! hole: `server_version2` (pulse 16.0) moved `default_sink_name` from
//! offset 40 to 48; both are tried.
//!
//! Lifecycle: attach is attempted once and cached by the volume segment; a
//! failed attach tears every handle down so the next probe starts clean.
//! One-shot ops never overlap (per-op state in module globals), and each
//! op's userdata carries its generation so a late callback is dropped.

const std = @import("std");
const core = @import("core");
const slider = @import("slider");

const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("errno.h");
    @cInclude("stdlib.h");
});

pub const PA_VOLUME_NORM: u32 = 0x10000;
const PA_INVALID_INDEX: u32 = 0xFFFFFFFF;

const PA_STATE_READY = 4;
const PA_STATE_FAILED = 5;
const PA_STATE_TERMINATED = 6;

/// Offsets into `pa_sink_info` (stable across the supported era):
/// name* @0, index u32 @8, description* @16, sample_spec @24, channel_map
/// @33, owner_module u32 @68, volume pa_cvolume @72 { u8 channels;
/// u32 values[32] } (132 bytes), muted int @140.
pub const sink_info_index: usize = 8;
const sink_info_volume: usize = 72;
pub const sink_info_channel_bytes: usize = sink_info_volume;
pub const sink_info_muted: usize = 140;

/// `default_sink_name` in `pa_server_info`: offset 40 pre-16.0, 48 in 16.0+.
const server_default_sink_offsets = [_]usize{ 48, 40 };

/// Opaque handles resolved at attach; safe: set before any operation.
/// Owner state (P2-58): attach handles, pending op result slots, and the
/// per-op parameters (single-threaded, never overlapping). Each op's
/// userdata carries its generation so a late callback is dropped.
const PulseState = struct {
    mainloop: ?*anyopaque = null,
    oplib: ?Lib = null,
    ctx: ?*anyopaque = null,
    server: ServerInfoResult = .{},
    sink: SinkInfoResult = .{},
    op_index: u32 = PA_INVALID_INDEX,
    op_mute: c_int = 0,
    op_vol: [132]u8 = undefined,
    op_name: [257]u8 = undefined,
    op_name_len: usize = 0,
    active_gen: usize = 0,
};
var g: PulseState = .{};

const ServerInfoResult = struct {
    done: bool = false,
    found_name: bool = false,
    name: [256]u8 = undefined,
    name_len: usize = 0,
};

const SinkInfoResult = struct {
    done: bool = false,
    found: bool = false,
    index: u32 = PA_INVALID_INDEX,
    channels: u8 = 0,
    muted: bool = false,
    pct: u8 = 0,
};

// Function-pointer types for every resolved libpulse symbol.
const FnMainloopNew = *const fn () callconv(.c) ?*anyopaque;
const FnMainloopFree = *const fn (?*anyopaque) callconv(.c) void;
const FnMainloopStart = *const fn (?*anyopaque) callconv(.c) c_int;
const FnMainloopStop = *const fn (?*anyopaque) callconv(.c) void;
const FnMainloopGetApi = *const fn (?*anyopaque) callconv(.c) ?*anyopaque;
const FnMainloopSignal = *const fn (?*anyopaque, c_int) callconv(.c) void;
const FnMainloopWait = *const fn (?*anyopaque) callconv(.c) c_int;
const FnMainloopLock = *const fn (?*anyopaque) callconv(.c) void;
const FnMainloopUnlock = *const fn (?*anyopaque) callconv(.c) void;
const FnContextNew = *const fn (?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque;
const FnContextFree = *const fn (?*anyopaque) callconv(.c) void;
const FnContextConnect = *const fn (?*anyopaque, ?[*:0]const u8, c_int, ?*const anyopaque) callconv(.c) c_int;
const FnContextDisconnect = *const fn (?*anyopaque) callconv(.c) void;
const FnContextGetState = *const fn (?*anyopaque) callconv(.c) c_int;
const FnServerInfoCb = *const fn (?*anyopaque, ?*const anyopaque, ?*anyopaque) callconv(.c) void;
const FnSinkInfoCb = *const fn (?*anyopaque, ?*const anyopaque, c_int, ?*anyopaque) callconv(.c) void;
const FnSuccessCb = *const fn (?*anyopaque, c_int, ?*anyopaque) callconv(.c) void;
const FnGetServerInfo = *const fn (?*anyopaque, FnServerInfoCb, ?*anyopaque) callconv(.c) ?*anyopaque;
const FnGetSinkInfoByName = *const fn (?*anyopaque, [*:0]const u8, FnSinkInfoCb, ?*anyopaque) callconv(.c) ?*anyopaque;
const FnGetSinkInfoByIndex = *const fn (?*anyopaque, u32, FnSinkInfoCb, ?*anyopaque) callconv(.c) ?*anyopaque;
const FnGetSinkInfoList = *const fn (?*anyopaque, FnSinkInfoCb, ?*anyopaque) callconv(.c) ?*anyopaque;
const FnSetSinkVolume = *const fn (?*anyopaque, u32, *const anyopaque, FnSuccessCb, ?*anyopaque) callconv(.c) ?*anyopaque;
const FnSetSinkMute = *const fn (?*anyopaque, u32, c_int, FnSuccessCb, ?*anyopaque) callconv(.c) ?*anyopaque;
const FnOperationUnref = *const fn (?*anyopaque) callconv(.c) void;

const Lib = struct {
    _lib: std.DynLib,
    mainloop_new: FnMainloopNew,
    mainloop_free: FnMainloopFree,
    mainloop_start: FnMainloopStart,
    mainloop_stop: FnMainloopStop,
    mainloop_get_api: FnMainloopGetApi,
    mainloop_signal: FnMainloopSignal,
    mainloop_wait: FnMainloopWait,
    mainloop_lock: FnMainloopLock,
    mainloop_unlock: FnMainloopUnlock,
    context_new: FnContextNew,
    context_free: FnContextFree,
    context_connect: FnContextConnect,
    context_disconnect: FnContextDisconnect,
    context_get_state: FnContextGetState,
    get_server_info: FnGetServerInfo,
    get_sink_info_by_name: FnGetSinkInfoByName,
    get_sink_info_by_index: FnGetSinkInfoByIndex,
    get_sink_info_list: FnGetSinkInfoList,
    set_sink_volume: FnSetSinkVolume,
    set_sink_mute: FnSetSinkMute,
    operation_unref: FnOperationUnref,
};

/// True when a PulseAudio-style runtime is present (the native protocol
/// socket under `$XDG_RUNTIME_DIR`/`/run/user/<uid>`). The ALSA-control
/// native backend is only valid on systems where this probe is false.
/// NOTE: the `/run/user/{uid}` fallback is PulseAudio's own convention,
/// not the `/tmp/{name}-{uid}` state-file policy shared by
/// config/persist snapshot.runtimeFile; the two deliberately differ.
pub fn pulseReachable() bool {
    var buf: [192]u8 = undefined;
    const base = if (c.getenv("XDG_RUNTIME_DIR")) |env|
        std.mem.span(env)
    else blk: {
        const uid = c.getuid();
        break :blk std.fmt.bufPrint(&buf, "/run/user/{d}", .{uid}) catch return false;
    };
    var p: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&p, "{s}/pulse/native", .{base}) catch return false;
    if (path.len >= p.len) return false;
    p[path.len] = 0;
    return c.access(&p, c.F_OK) == 0;
}

// Pure byte-buffer helpers (unit-tested without libpulse or a daemon)

fn readLE(comptime T: type, b: []const u8, off: usize) T {
    return std.mem.readInt(T, b[off..][0..@sizeOf(T)], .little);
}

fn writeLE(comptime T: type, b: []u8, off: usize, v: T) void {
    std.mem.writeInt(T, b[off..][0..@sizeOf(T)], v, .little);
}

/// A sink name must start with a letter or underscore and contain only
/// printable ASCII (checked up to a sane limit).
pub fn plausibleSinkName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    const first = name[0];
    if (!((first >= 'a' and first <= 'z') or (first >= 'A' and first <= 'Z') or first == '_')) return false;
    for (name) |ch| {
        if (ch < 0x20 or ch == 0x7f) return false;
    }
    return true;
}

/// Extracts `default_sink_name` from raw `pa_server_info` bytes, trying the
/// pre-16.0 offset (40) and the 16.0+ offset (48).
pub fn readDefaultSink(info: []const u8) ?[]const u8 {
    for (server_default_sink_offsets) |off| {
        if (off + @sizeOf(usize) > info.len) continue;
        const ptr_val = readLE(usize, info, off);
        if (ptr_val == 0) continue;
        const s = @as([*]const u8, @ptrFromInt(ptr_val));
        const n = std.mem.indexOfScalar(u8, s[0..128], 0) orelse continue;
        const name = s[0..n];
        if (plausibleSinkName(name)) return name;
    }
    return null;
}

/// Parses a raw `pa_sink_info` snapshot into index/channels/muted.
pub fn parseSinkInfo(buf: []const u8) ?struct { index: u32, channels: u8, muted: bool } {
    if (buf.len < sink_info_muted + 4) return null;
    const index = readLE(u32, buf, sink_info_index);
    if (index == PA_INVALID_INDEX) return null;
    const channels = buf[sink_info_channel_bytes];
    if (channels == 0 or channels > 32) return null;
    const muted_i = readLE(i32, buf, sink_info_muted);
    return .{ .index = index, .channels = channels, .muted = muted_i != 0 };
}

/// Percentage from the sink's volume snapshot (`pvol` = volume bytes).
pub fn volumePct(pvol: []const u8, channels: u8) ?u8 {
    const n: usize = if (channels > 32) 32 else @as(usize, channels);
    if (n == 0 or pvol.len < 4 + n * 4) return null;
    var sum: u64 = 0;
    for (0..n) |i| sum += readLE(u32, pvol, 4 + i * 4);
    const avg = sum / n;
    // The SHARED map, not a local formula: truncating in opposite directions
    // on write and read would disagree by up to 1% on 96 of 101 levels, so
    // writing 5% and reading it back could show 4% and the segment would fight
    // the user. slider.rawFromPct/pctFromRaw round to nearest in both
    // directions, which makes the round trip exact.
    return slider.pctFromRaw(u32, @intCast(avg), 0, PA_VOLUME_NORM);
}

/// Builds a `pa_cvolume` (channels byte + per-channel u32 values) for `pct`
/// into `out` (needs >= 4 + channels*4 bytes). Uses the shared percent<->raw
/// map, so it agrees with `volumePct` and with `pa_sw_volume_from_percentage`
/// to the nearest step.
pub fn buildCvolume(pct: u8, channels: u8, out: []u8) bool {
    const n: usize = if (channels > 32) 32 else @as(usize, channels);
    if (n == 0) return false;
    if (out.len < 4 + n * 4) return false;
    @memset(out[0 .. 4 + n * 4], 0);
    out[0] = @intCast(n);
    const v: u32 = slider.rawFromPct(u32, pct, 0, PA_VOLUME_NORM);
    for (0..n) |i| writeLE(u32, out, 4 + i * 4, v);
    return true;
}

/// Bound on a COMMIT wait (D21): a commit is a single socket round-trip, so
/// anything near this bound means the daemon is wedged, not slow. Blocking the
/// event loop for the old 100 ms made a dead daemon cost the WM frame; at 50
/// ms the wait is capped and a timeout degrades to the optimistic path (see
/// `commitVerdict`) instead of stalling the bar.
pub const commit_wait_ms: i64 = 50;

/// A timed-out wait is treated as SUCCESS -- the display updates now and the
/// 5 s read reconciles -- because blocking the event loop on every scroll tick
/// of a wedged daemon is exactly the frame stall this bound exists to
/// prevent. A completed wait still defers to the daemon: a rejection must
/// never read as applied.
pub fn commitVerdict(done: bool, found: bool) bool {
    return !done or found;
}

// Operation plumbing

// Generation of the newest op is bumped (under the mainloop lock) each time
// an op is issued or the backend is torn down. Carried into every callback as
// the userdata value, so a stale callback identifies itself and is dropped
// before it can write or signal.

fn genUserdata(gen: usize) ?*anyopaque {
    // +1 keeps a live gen distinct from a null userdata.
    return @ptrFromInt(gen + 1);
}

fn genIsCurrent(ud: ?*anyopaque) bool {
    const p = @intFromPtr(ud);
    // Null userdata is never issued here; treat it as current, because
    // dropping a signal a waiter IS parked on is the failure mode this gate
    // exists to prevent.
    if (p == 0) return true;
    return p - 1 == g.active_gen;
}

/// Waits (mainloop lock held) for `done`, bounded by `timeout_ms` and by the
/// context leaving a dead state. Correctness depends on every terminal
/// callback path signaling `done` (libpulse guarantees one invocation per
/// op; `sinkInfoCb` covers the `info == NULL` forms).
fn waitDone(done: *bool, timeout_ms: i64) bool {
    const lib = g.oplib.?;
    const m = g.mainloop.?;
    const ctx = g.ctx.?;
    const deadline = core.realtimeMs() + timeout_ms;
    lib.mainloop_lock(m);
    defer lib.mainloop_unlock(m);
    while (!done.*) {
        if (core.realtimeMs() >= deadline) return false;
        const st = lib.context_get_state(ctx);
        if (st == PA_STATE_FAILED or st == PA_STATE_TERMINATED) return false;
        _ = lib.mainloop_wait(m);
    }
    return true;
}

const IssueFn = *const fn (*anyopaque) ?*anyopaque;

/// Issues an async pa_* operation under the lock, then waits (bounded) for
/// its callback. Returns whether a callback delivered a result.
fn runOp(issue: IssueFn, done: *bool, timeout_ms: i64) bool {
    const lib = g.oplib.?;
    const m = g.mainloop.?;
    lib.mainloop_lock(m);
    g.active_gen += 1;
    const op = issue(g.ctx.?);
    if (op == null) {
        // Op creation failed => libpulse registered no callback, so nothing
        // can signal; report failure without waiting out the deadline.
        lib.mainloop_unlock(m);
        return false;
    }
    lib.mainloop_unlock(m);
    const ok = waitDone(done, timeout_ms);
    // Re-take the lock before unref so the unref cannot interleave with an
    // in-flight callback's final writes; a stale post-timeout callback is
    // rejected by its generation, not by this unref.
    lib.mainloop_lock(m);
    lib.operation_unref(op);
    lib.mainloop_unlock(m);
    return ok;
}

// Issue stubs (params from the module globals). Each op's userdata is the
// generation current at issue time (stubs run synchronously under the lock
// right after `runOp`'s bump).
fn issueServerInfo(ctx: *anyopaque) ?*anyopaque {
    return g.oplib.?.get_server_info(ctx, serverInfoCb, genUserdata(g.active_gen));
}
fn issueSinkByName(ctx: *anyopaque) ?*anyopaque {
    return g.oplib.?.get_sink_info_by_name(ctx, g.op_name[0..g.op_name_len :0], sinkInfoCb, genUserdata(g.active_gen));
}
fn issueSinkByIndex(ctx: *anyopaque) ?*anyopaque {
    return g.oplib.?.get_sink_info_by_index(ctx, g.op_index, sinkInfoCb, genUserdata(g.active_gen));
}
fn issueSinkList(ctx: *anyopaque) ?*anyopaque {
    return g.oplib.?.get_sink_info_list(ctx, sinkInfoCb, genUserdata(g.active_gen));
}
fn issueSetVolume(ctx: *anyopaque) ?*anyopaque {
    return g.oplib.?.set_sink_volume(ctx, g.op_index, @ptrCast(&g.op_vol), successCb, genUserdata(g.active_gen));
}
fn issueSetMute(ctx: *anyopaque) ?*anyopaque {
    return g.oplib.?.set_sink_mute(ctx, g.op_index, g.op_mute, successCb, genUserdata(g.active_gen));
}

fn signalDone(done: *bool) void {
    done.* = true;
    if (g.mainloop) |m| if (g.oplib) |lib| lib.mainloop_signal(m, 0);
}

fn serverInfoCb(_: ?*anyopaque, info: ?*const anyopaque, userdata: ?*anyopaque) callconv(.c) void {
    if (!genIsCurrent(userdata)) return;
    if (info) |i| {
        const ptr = @as([*]const u8, @ptrCast(@constCast(i)));
        if (readDefaultSink(ptr[0..512])) |name| {
            const n = @min(name.len, g.server.name.len);
            @memcpy(g.server.name[0..n], name);
            g.server.name_len = n;
            g.server.found_name = true;
        }
    }
    signalDone(&g.server.done);
}

fn sinkInfoCb(_: ?*anyopaque, info: ?*const anyopaque, eol: c_int, userdata: ?*anyopaque) callconv(.c) void {
    if (!genIsCurrent(userdata)) return;
    if (info == null) {
        // The terminal callback is `info == NULL, eol != 0` for BOTH an empty
        // list and an operation error. Returning without signaling would
        // leave `waitDone` parked in `mainloop_wait` with no wake to re-check
        // its deadline -- i.e. a frozen WM. Signal on every terminal form;
        // `found` stays as whatever a prior entry set.
        if (eol != 0) signalDone(&g.sink.done);
        return;
    }
    if (eol != 0) {
        // List exhaustion: no more entries; the first guarded entry (set
        // above on a non-eol call) is what `found` keeps.
        signalDone(&g.sink.done);
        return;
    }
    const ptr = @as([*]const u8, @ptrCast(@constCast(info)));
    if (parseSinkInfo(ptr[0 .. sink_info_muted + 4])) |snap| {
        if (!g.sink.found) {
            if (volumePct(ptr[sink_info_volume..][0..132], snap.channels)) |p| {
                g.sink.index = snap.index;
                g.sink.channels = snap.channels;
                g.sink.muted = snap.muted;
                g.sink.pct = p;
                g.sink.found = true;
                // by-name/by-index deliver exactly one entry then end without
                // an eol callback, so nothing else would ever signal `done`:
                // signaling here is what keeps the single-info queries from
                // waiting out their full timeout. The list query ends the same
                // way on its first usable entry instead of scanning on.
                signalDone(&g.sink.done);
            }
        }
    }
}

fn successCb(_: ?*anyopaque, success: c_int, userdata: ?*anyopaque) callconv(.c) void {
    if (!genIsCurrent(userdata)) return;
    g.sink.found = success != 0;
    signalDone(&g.sink.done);
}

// Attach

fn openLib() ?Lib {
    var dl = std.DynLib.open("libpulse.so.0") catch return null;
    return .{
        ._lib = dl,
        .mainloop_new = lookupKnown(&dl, FnMainloopNew, "pa_threaded_mainloop_new") orelse return missOpen(dl),
        .mainloop_free = lookupKnown(&dl, FnMainloopFree, "pa_threaded_mainloop_free") orelse return missOpen(dl),
        .mainloop_start = lookupKnown(&dl, FnMainloopStart, "pa_threaded_mainloop_start") orelse return missOpen(dl),
        .mainloop_stop = lookupKnown(&dl, FnMainloopStop, "pa_threaded_mainloop_stop") orelse return missOpen(dl),
        .mainloop_get_api = lookupKnown(&dl, FnMainloopGetApi, "pa_threaded_mainloop_get_api") orelse return missOpen(dl),
        .mainloop_signal = lookupKnown(&dl, FnMainloopSignal, "pa_threaded_mainloop_signal") orelse return missOpen(dl),
        .mainloop_wait = lookupKnown(&dl, FnMainloopWait, "pa_threaded_mainloop_wait") orelse return missOpen(dl),
        .mainloop_lock = lookupKnown(&dl, FnMainloopLock, "pa_threaded_mainloop_lock") orelse return missOpen(dl),
        .mainloop_unlock = lookupKnown(&dl, FnMainloopUnlock, "pa_threaded_mainloop_unlock") orelse return missOpen(dl),
        .context_new = lookupKnown(&dl, FnContextNew, "pa_context_new") orelse return missOpen(dl),
        .context_free = lookupKnown(&dl, FnContextFree, "pa_context_free") orelse return missOpen(dl),
        .context_connect = lookupKnown(&dl, FnContextConnect, "pa_context_connect") orelse return missOpen(dl),
        .context_disconnect = lookupKnown(&dl, FnContextDisconnect, "pa_context_disconnect") orelse return missOpen(dl),
        .context_get_state = lookupKnown(&dl, FnContextGetState, "pa_context_get_state") orelse return missOpen(dl),
        .get_server_info = lookupKnown(&dl, FnGetServerInfo, "pa_context_get_server_info") orelse return missOpen(dl),
        .get_sink_info_by_name = lookupKnown(&dl, FnGetSinkInfoByName, "pa_context_get_sink_info_by_name") orelse return missOpen(dl),
        .get_sink_info_by_index = lookupKnown(&dl, FnGetSinkInfoByIndex, "pa_context_get_sink_info_by_index") orelse return missOpen(dl),
        .get_sink_info_list = lookupKnown(&dl, FnGetSinkInfoList, "pa_context_get_sink_info_list") orelse return missOpen(dl),
        .set_sink_volume = lookupKnown(&dl, FnSetSinkVolume, "pa_context_set_sink_volume_by_index") orelse return missOpen(dl),
        .set_sink_mute = lookupKnown(&dl, FnSetSinkMute, "pa_context_set_sink_mute_by_index") orelse return missOpen(dl),
        .operation_unref = lookupKnown(&dl, FnOperationUnref, "pa_operation_unref") orelse return missOpen(dl),
    };
    // A missing symbol closes the handle before giving up: attach can now
    // retry after a teardown, and an unclosed miss would leak one dlopen per
    // probe instead of one per session.
}

fn missOpen(dl: std.DynLib) ?Lib {
    var handle = dl;
    handle.close();
    return null;
}

fn lookupKnown(lib: *std.DynLib, comptime ftype: type, name: [:0]const u8) ?ftype {
    return lib.lookup(ftype, name);
}

/// Waits for the context to reach READY (bounded), with the lock held.
fn waitReady(timeout_ms: i64) bool {
    const lib = g.oplib.?;
    const m = g.mainloop.?;
    const ctx = g.ctx.?;
    const deadline = core.realtimeMs() + timeout_ms;
    lib.mainloop_lock(m);
    defer lib.mainloop_unlock(m);
    while (true) {
        const st = lib.context_get_state(ctx);
        if (st == PA_STATE_READY) return true;
        if (st == PA_STATE_FAILED or st == PA_STATE_TERMINATED) return false;
        if (core.realtimeMs() >= deadline) return false;
        _ = lib.mainloop_wait(m);
    }
}

/// Tears down a failed attach so no worker thread, context, mainloop or
/// dlopen handle outlives the failure: a retry starts from zero, and
/// stopping the worker FIRST guarantees no callback is in flight while the
/// objects it would touch are freed. Returns null for `return abortAttach(...)`
/// call sites.
fn abortAttach(lib: Lib, m: ?*anyopaque, ctx: ?*anyopaque, started: bool) ?Backend {
    if (ctx != null and started) {
        // Disconnect under the lock (the worker is still alive and owns the
        // connection), then stop the worker before any free.
        lib.mainloop_lock(m.?);
        lib.context_disconnect(ctx.?);
        lib.mainloop_unlock(m.?);
    }
    if (started) lib.mainloop_stop(m.?);
    if (ctx) |ctxp| lib.context_free(ctxp);
    if (m) |mm| lib.mainloop_free(mm);
    g.oplib = null;
    g.mainloop = null;
    g.ctx = null;
    // Invalidate any straggler callback of the dead backend: its generation
    // can no longer match, so it can neither write results nor signal a
    // future waiter.
    g.active_gen += 1;
    var handle = lib._lib;
    handle.close();
    return null;
}

/// Attempts to attach to the local PulseAudio/PipeWire daemon. Returns null
/// (never crashes) when the library, daemon, or ABI guards are unavailable,
/// with every partially-built object torn down first.
pub fn attach() ?Backend {
    if (!pulseReachable()) return null;
    const lib = openLib() orelse return null;

    const m = lib.mainloop_new() orelse {
        var handle = lib._lib;
        handle.close();
        return null;
    };
    const api = lib.mainloop_get_api(m) orelse {
        lib.mainloop_free(m);
        var handle = lib._lib;
        handle.close();
        return null;
    };
    const ctx = lib.context_new(api, "hana") orelse {
        lib.mainloop_free(m);
        var handle = lib._lib;
        handle.close();
        return null;
    };

    g.oplib = lib;
    g.mainloop = m;
    g.ctx = ctx;
    g.active_gen += 1;

    lib.mainloop_lock(m);
    const rc = lib.context_connect(ctx, null, 0, null);
    lib.mainloop_unlock(m);
    if (rc < 0) return abortAttach(lib, m, ctx, false);

    if (lib.mainloop_start(m) < 0) return abortAttach(lib, m, ctx, false);
    if (!waitReady(2000)) return abortAttach(lib, m, ctx, true);

    // Resolve the default sink: server_info first, then the list fallback.
    var index: u32 = PA_INVALID_INDEX;
    var channels: u8 = 0;
    {
        g.server = .{};
        if (runOp(issueServerInfo, &g.server.done, 1500) and g.server.found_name) {
            const name = g.server.name[0..g.server.name_len];
            g.op_name_len = @min(name.len, g.op_name.len - 1);
            @memcpy(g.op_name[0..g.op_name_len], name);
            g.op_name[g.op_name_len] = 0;

            g.sink = .{};
            if (runOp(issueSinkByName, &g.sink.done, 1500) and g.sink.found) {
                index = g.sink.index;
                channels = g.sink.channels;
            }
        }
        if (index == PA_INVALID_INDEX) {
            g.sink = .{};
            _ = runOp(issueSinkList, &g.sink.done, 1500);
            if (g.sink.found) {
                index = g.sink.index;
                channels = g.sink.channels;
            }
        }
        if (index == PA_INVALID_INDEX) return abortAttach(lib, m, ctx, true);
    }

    return .{
        .lib = lib,
        .m = m,
        .ctx = ctx,
        .index = index,
        .channels = channels,
        .muted = g.sink.muted,
    };
}

/// Attached native backend, owned by the volume segment.
pub const Backend = struct {
    lib: Lib,
    m: *anyopaque,
    ctx: *anyopaque,
    index: u32,
    channels: u8,
    muted: bool,

    /// Detaches the backend: stop the worker, disconnect, free everything,
    /// clear the owner state (`PulseState`). Deinit ordering contract
    /// (P2-58): the single-backend module's `PulseState` fields ARE the
    /// handles this `Backend` was built from, so the caller (the volume
    /// segment) must drop its own copy of the `Backend` immediately after
    /// this returns -- the `lib` function pointers inside it are dead once
    /// the dlopen handle closes. Concretely: (1) stop+disconnect the
    /// mainloop under the lock, (2) free the context, (3) free the mainloop,
    /// (4) close the DynLib (which invalidates every `Fn*` pointer), (5)
    /// null the `PulseState` handles so a late probe re-attaches. Nothing
    /// may call into `lib` after step (4).
    pub fn deinit(_: *Backend) void {
        _ = abortAttach(g.oplib.?, g.mainloop, g.ctx, true);
    }

    /// In-process volume commit: one native-protocol round trip, bounded by
    /// `commit_wait_ms`. A timeout is optimistic success (D21): the display
    /// updates now and the 5 s read reconciles, rather than stalling the
    /// event loop for a wedged daemon.
    pub fn setVolumePct(self: *const Backend, pct: u8) bool {
        if (!buildCvolume(pct, self.channels, &g.op_vol)) return false;
        g.op_index = self.index;
        g.sink = .{};
        const done = runOp(issueSetVolume, &g.sink.done, commit_wait_ms);
        // `commitVerdict`: timeout => optimistic; completed => the daemon's
        // verdict (`found`), since successCb fires done with found=false when
        // the daemon rejects the op.
        return commitVerdict(done, g.sink.found);
    }

    /// In-process mute commit: one native-protocol round trip, the
    /// toggleMute path's native counterpart (the subprocess rungs
    /// `toggle` blindly; the native protocol takes an absolute state,
    /// so the segment passes the inverted observed state). Bounded by
    /// `commit_wait_ms` with the same optimistic-on-timeout rule (D21) as
    /// `setVolumePct`.
    pub fn setMuted(self: *const Backend, muted: bool) bool {
        g.op_index = self.index;
        g.op_mute = @intFromBool(muted);
        g.sink = .{};
        const done = runOp(issueSetMute, &g.sink.done, commit_wait_ms);
        // `commitVerdict`: timeout => optimistic; completed => the daemon's
        // verdict (`found`), so a rejected op still reports failure.
        return commitVerdict(done, g.sink.found);
    }

    /// Reads back the live sink state natively (volume + mute).
    pub fn readSink(self: *Backend) ?struct { pct: u8, muted: bool } {
        g.op_index = self.index;
        g.sink = .{};
        _ = runOp(issueSinkByIndex, &g.sink.done, 300);
        if (!g.sink.found) return null;
        self.muted = g.sink.muted;
        return .{ .pct = g.sink.pct, .muted = g.sink.muted };
    }
};
