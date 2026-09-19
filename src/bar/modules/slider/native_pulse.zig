//! Native PulseAudio backend for the volume segment, via runtime `dlopen` of
//! `libpulse.so.0` -- no headers, no link-time dependency, no subprocess.
//!
//! Every commit (`setVolumePct`, `setMuted`) and read (`readSink`, used on
//! the 5 s read cadence) is an in-process call into a threaded mainloop that
//! talks the native protocol straight to the PulseAudio/PipeWire daemon.
//! Commits are single socket round-trips (tens of microseconds, no
//! fork/exec/pipe), which is what makes per-event, un-throttled volume
//! scrolls/drags possible on PipeWire/PulseAudio machines -- including ones
//! like the box this was developed on, where `pactl` is unavailable but
//! `/run/user/$uid/pulse/native` is served by PipeWire.
//!
//! The module links NOTHING at build time: symbols are resolved at runtime
//! with `std.DynLib`. On a machine without `libpulse.so.0` the attach fails
//! cleanly and the volume segment falls back to its `pactl`/`amixer`
//! subprocess path, so this module compiles everywhere and is only exercised
//! where the library exists.
//!
//! ABI discipline: instead of linking the pulse headers, the handful of
//! structs we touch are read as raw bytes. Layouts are stable across the
//! pulse 1.x-16.x era, but every field is guard-checked at runtime. If any
//! guard fails the backend is abandoned and the spawn fallback is used.
//! `pa_server_info` DOES have a version-dependent hole: `server_version2` was
//! added in pulse 16.0, moving `default_sink_name` from offset 40 to 48; both
//! are tried, selecting the first that looks like a sink name.
//!
//! Lifecycle: attach is attempted once and cached by the volume segment. All
//! operations are issued under the mainloop lock with a bounded wait, so a
//! dead daemon cannot hang the WM's event loop. One-shot ops never overlap
//! (single-threaded event loop), so per-op state lives in module globals.

const std = @import("std");
const utils = @import("utils");

const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("errno.h");
    @cInclude("stdlib.h");
});

const PA_VOLUME_NORM: u32 = 0x10000;
const PA_INVALID_INDEX: u32 = 0xFFFFFFFF;

const PA_STATE_READY = 4;
const PA_STATE_FAILED = 5;
const PA_STATE_TERMINATED = 6;

/// Offsets into `pa_sink_info` (stable across the supported era):
///   name* @0, index u32 @8, description* @16, sample_spec @24 (u32+u32+u8 =
///   9 bytes), channel_map @33 (u8 + u8[32] = 33 bytes), owner_module u32
///   @68, volume pa_cvolume @72 { u8 channels; u32 values[32] } (132 bytes),
///   muted int @140, and then the tail that later versions extend.
const sink_info_index: usize = 8;
const sink_info_volume: usize = 72;
const sink_info_channel_bytes: usize = sink_info_volume;
const sink_info_volume_values: usize = sink_info_volume + 4;
const sink_info_muted: usize = 140;

/// `default_sink_name` in `pa_server_info`: offset 40 pre-16.0, 48 in 16.0+.
const server_default_sink_offsets = [_]usize{ 48, 40 };

/// Opaque handles resolved at attach (worker + lib), needed by callbacks that
/// run on the mainloop thread. Safe: set before any operation, never cleared.
var g_mainloop: ?*anyopaque = null;
var g_oplib: ?Lib = null;
var g_ctx: ?*anyopaque = null;

/// Results of the pending operation, produced by callbacks, consumed after
/// `runOp` returns.
var g_server = ServerInfoResult{};
var g_sink = SinkInfoResult{};

/// Per-op parameters (single-threaded, never overlapping).
var g_op_index: u32 = PA_INVALID_INDEX;
var g_op_mute: c_int = 0;
var g_op_muted_current: bool = false;
var g_op_vol: [132]u8 = undefined;
var g_op_name: [257]u8 = undefined;
var g_op_name_len: usize = 0;

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
const FnMainloopGetApi = *const fn (?*anyopaque) callconv(.c) ?*anyopaque;
const FnMainloopSignal = *const fn (?*anyopaque, c_int) callconv(.c) void;
const FnMainloopWait = *const fn (?*anyopaque) callconv(.c) c_int;
const FnMainloopLock = *const fn (?*anyopaque) callconv(.c) void;
const FnMainloopUnlock = *const fn (?*anyopaque) callconv(.c) void;
const FnContextNew = *const fn (?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque;
const FnContextFree = *const fn (?*anyopaque) callconv(.c) void;
const FnContextConnect = *const fn (?*anyopaque, ?[*:0]const u8, c_int, ?*const anyopaque) callconv(.c) c_int;
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
    mainloop_get_api: FnMainloopGetApi,
    mainloop_signal: FnMainloopSignal,
    mainloop_wait: FnMainloopWait,
    mainloop_lock: FnMainloopLock,
    mainloop_unlock: FnMainloopUnlock,
    context_new: FnContextNew,
    context_free: FnContextFree,
    context_connect: FnContextConnect,
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
/// socket under `$XDG_RUNTIME_DIR`/`/run/user/<uid>`), i.e. sound is served
/// through PipeWire/PulseAudio rather than raw ALSA. The ALSA-control native
/// backend is only valid (matches amixer's `Master`) on systems where this
/// probe is false.
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

// --- Pure byte-buffer helpers (unit-tested without libpulse or a daemon) ---

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
    return @intCast(@min(@as(u64, avg) * 100 / PA_VOLUME_NORM, 100));
}

/// Builds a `pa_cvolume` (channels byte + per-channel u32 values) for `pct`
/// into `out` (needs >= 4 + channels*4 bytes). Linear mapping matches
/// `pa_sw_volume_from_percentage`.
pub fn buildCvolume(pct: u8, channels: u8, out: []u8) bool {
    const n: usize = if (channels > 32) 32 else @as(usize, channels);
    if (n == 0) return false;
    if (out.len < 4 + n * 4) return false;
    @memset(out[0 .. 4 + n * 4], 0);
    out[0] = @intCast(n);
    const v: u32 = @intCast(@as(u64, @min(pct, 100)) * PA_VOLUME_NORM / 100);
    for (0..n) |i| writeLE(u32, out, 4 + i * 4, v);
    return true;
}

// --- Operation plumbing ---

fn nowMs() i64 {
    return @intCast(utils.realtimeNs() / std.time.ns_per_ms);
}

/// Waits (with the mainloop lock held) for `done`, bounded by `timeout_ms`.
fn waitDone(done: *bool, timeout_ms: i64) bool {
    const lib = g_oplib.?;
    const m = g_mainloop.?;
    const deadline = nowMs() + timeout_ms;
    lib.mainloop_lock(m);
    defer lib.mainloop_unlock(m);
    while (!done.*) {
        if (nowMs() >= deadline) return false;
        _ = lib.mainloop_wait(m);
    }
    return true;
}

const IssueFn = *const fn (*anyopaque) ?*anyopaque;

/// Issues an async pa_* operation under the lock, then waits (bounded) for
/// its callback to fire. Returns whether a callback delivered a result.
fn runOp(issue: IssueFn, done: *bool, timeout_ms: i64) bool {
    const lib = g_oplib.?;
    const m = g_mainloop.?;
    lib.mainloop_lock(m);
    const op = issue(g_ctx.?);
    if (op == null) {
        lib.mainloop_unlock(m);
        return false;
    }
    lib.mainloop_unlock(m);
    const ok = waitDone(done, timeout_ms);
    lib.operation_unref(op);
    return ok;
}

// Issue stubs (params from the module globals).
fn issueServerInfo(ctx: *anyopaque) ?*anyopaque {
    return g_oplib.?.get_server_info(ctx, serverInfoCb, null);
}
fn issueSinkByName(ctx: *anyopaque) ?*anyopaque {
    return g_oplib.?.get_sink_info_by_name(ctx, g_op_name[0..g_op_name_len :0], sinkInfoCb, null);
}
fn issueSinkByIndex(ctx: *anyopaque) ?*anyopaque {
    return g_oplib.?.get_sink_info_by_index(ctx, g_op_index, sinkInfoCb, null);
}
fn issueSinkList(ctx: *anyopaque) ?*anyopaque {
    return g_oplib.?.get_sink_info_list(ctx, sinkInfoCb, null);
}
fn issueSetVolume(ctx: *anyopaque) ?*anyopaque {
    return g_oplib.?.set_sink_volume(ctx, g_op_index, @ptrCast(&g_op_vol), successCb, null);
}
fn issueSetMute(ctx: *anyopaque) ?*anyopaque {
    return g_oplib.?.set_sink_mute(ctx, g_op_index, g_op_mute, successCb, null);
}

fn signalDone(done: *bool) void {
    done.* = true;
    if (g_mainloop) |m| if (g_oplib) |lib| lib.mainloop_signal(m, 0);
}

fn serverInfoCb(_: ?*anyopaque, info: ?*const anyopaque, _: ?*anyopaque) callconv(.c) void {
    if (info) |i| {
        const ptr = @as([*]const u8, @ptrCast(@constCast(i)));
        if (readDefaultSink(ptr[0..512])) |name| {
            const n = @min(name.len, g_server.name.len);
            @memcpy(g_server.name[0..n], name);
            g_server.name_len = n;
            g_server.found_name = true;
        }
    }
    signalDone(&g_server.done);
}

fn sinkInfoCb(_: ?*anyopaque, info: ?*const anyopaque, eol: c_int, _: ?*anyopaque) callconv(.c) void {
    if (info == null) return;
    if (eol != 0) {
        // List exhaustion: no more entries; the first guarded entry (set
        // above on a non-eol call) is what `found` keeps.
        signalDone(&g_sink.done);
        return;
    }
    const ptr = @as([*]const u8, @ptrCast(@constCast(info)));
    if (parseSinkInfo(ptr[0 .. sink_info_muted + 4])) |snap| {
        if (!g_sink.found) {
            if (volumePct(ptr[sink_info_volume..][0..132], snap.channels)) |p| {
                g_sink.index = snap.index;
                g_sink.channels = snap.channels;
                g_sink.muted = snap.muted;
                g_sink.pct = p;
                g_sink.found = true;
            }
        }
    }
}

fn successCb(_: ?*anyopaque, success: c_int, _: ?*anyopaque) callconv(.c) void {
    g_sink.found = success != 0;
    signalDone(&g_sink.done);
}

// --- Attach ---

fn openLib() ?Lib {
    var lib = std.DynLib.open("libpulse.so.0") catch return null;
    return .{
        ._lib = lib,
        .mainloop_new = lookupKnown(&lib, FnMainloopNew, "pa_threaded_mainloop_new") orelse return null,
        .mainloop_free = lookupKnown(&lib, FnMainloopFree, "pa_threaded_mainloop_free") orelse return null,
        .mainloop_start = lookupKnown(&lib, FnMainloopStart, "pa_threaded_mainloop_start") orelse return null,
        .mainloop_get_api = lookupKnown(&lib, FnMainloopGetApi, "pa_threaded_mainloop_get_api") orelse return null,
        .mainloop_signal = lookupKnown(&lib, FnMainloopSignal, "pa_threaded_mainloop_signal") orelse return null,
        .mainloop_wait = lookupKnown(&lib, FnMainloopWait, "pa_threaded_mainloop_wait") orelse return null,
        .mainloop_lock = lookupKnown(&lib, FnMainloopLock, "pa_threaded_mainloop_lock") orelse return null,
        .mainloop_unlock = lookupKnown(&lib, FnMainloopUnlock, "pa_threaded_mainloop_unlock") orelse return null,
        .context_new = lookupKnown(&lib, FnContextNew, "pa_context_new") orelse return null,
        .context_free = lookupKnown(&lib, FnContextFree, "pa_context_free") orelse return null,
        .context_connect = lookupKnown(&lib, FnContextConnect, "pa_context_connect") orelse return null,
        .context_get_state = lookupKnown(&lib, FnContextGetState, "pa_context_get_state") orelse return null,
        .get_server_info = lookupKnown(&lib, FnGetServerInfo, "pa_context_get_server_info") orelse return null,
        .get_sink_info_by_name = lookupKnown(&lib, FnGetSinkInfoByName, "pa_context_get_sink_info_by_name") orelse return null,
        .get_sink_info_by_index = lookupKnown(&lib, FnGetSinkInfoByIndex, "pa_context_get_sink_info_by_index") orelse return null,
        .get_sink_info_list = lookupKnown(&lib, FnGetSinkInfoList, "pa_context_get_sink_info_list") orelse return null,
        .set_sink_volume = lookupKnown(&lib, FnSetSinkVolume, "pa_context_set_sink_volume_by_index") orelse return null,
        .set_sink_mute = lookupKnown(&lib, FnSetSinkMute, "pa_context_set_sink_mute_by_index") orelse return null,
        .operation_unref = lookupKnown(&lib, FnOperationUnref, "pa_operation_unref") orelse return null,
    };
    // A missing symbol leaks the opened handle on the failure path -- the
    // module is attached once per session and the leak is one dlopen.
}

fn lookupKnown(lib: *std.DynLib, comptime ftype: type, name: [:0]const u8) ?ftype {
    return lib.lookup(ftype, name);
}

/// Waits for the context to reach READY (bounded), with the lock held.
fn waitReady(timeout_ms: i64) bool {
    const lib = g_oplib.?;
    const m = g_mainloop.?;
    const ctx = g_ctx.?;
    const deadline = nowMs() + timeout_ms;
    lib.mainloop_lock(m);
    defer lib.mainloop_unlock(m);
    while (true) {
        const st = lib.context_get_state(ctx);
        if (st == PA_STATE_READY) return true;
        if (st == PA_STATE_FAILED or st == PA_STATE_TERMINATED) return false;
        if (nowMs() >= deadline) return false;
        _ = lib.mainloop_wait(m);
    }
}

/// Attempts to attach to the local PulseAudio/PipeWire daemon. Returns null
/// (never crashes) when the library, daemon, or ABI guards are unavailable.
pub fn attach() ?Backend {
    if (!pulseReachable()) return null;
    const lib = openLib() orelse return null;

    const m = lib.mainloop_new() orelse return null;
    const api = lib.mainloop_get_api(m) orelse return null;
    const ctx = lib.context_new(api, "hana") orelse return null;

    g_oplib = lib;
    g_mainloop = m;
    g_ctx = ctx;

    lib.mainloop_lock(m);
    const rc = lib.context_connect(ctx, null, 0, null);
    lib.mainloop_unlock(m);
    if (rc < 0) return null;

    if (lib.mainloop_start(m) < 0) return null;
    if (!waitReady(2000)) return null;

    // Resolve the default sink: server_info first, then the list fallback.
    var index: u32 = PA_INVALID_INDEX;
    var channels: u8 = 0;
    {
        g_server = .{};
        if (runOp(issueServerInfo, &g_server.done, 1500) and g_server.found_name) {
            const name = g_server.name[0..g_server.name_len];
            g_op_name_len = @min(name.len, g_op_name.len - 1);
            @memcpy(g_op_name[0..g_op_name_len], name);
            g_op_name[g_op_name_len] = 0;

            g_sink = .{};
            if (runOp(issueSinkByName, &g_sink.done, 1500) and g_sink.found) {
                index = g_sink.index;
                channels = g_sink.channels;
            }
        }
        if (index == PA_INVALID_INDEX) {
            g_sink = .{};
            _ = runOp(issueSinkList, &g_sink.done, 1500);
            if (g_sink.found) {
                index = g_sink.index;
                channels = g_sink.channels;
            }
        }
        if (index == PA_INVALID_INDEX) return null;
    }

    return .{
        .lib = lib,
        .m = m,
        .ctx = ctx,
        .index = index,
        .channels = channels,
        .muted = g_sink.muted,
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

    /// In-process volume commit: one native-protocol round trip.
    pub fn setVolumePct(self: *const Backend, pct: u8) bool {
        if (!buildCvolume(pct, self.channels, &g_op_vol)) return false;
        g_op_index = self.index;
        g_sink = .{};
        _ = runOp(issueSetVolume, &g_sink.done, 100);
        return g_sink.done;
    }

    /// In-process mute commit (uses the snapshot cached by the last read so
    /// an external change between polls doesn't invert).
    pub fn setMuted(self: *Backend, muted: bool) bool {
        g_op_index = self.index;
        g_op_mute = @intFromBool(muted);
        g_sink = .{};
        _ = runOp(issueSetMute, &g_sink.done, 100);
        if (g_sink.done) self.muted = muted;
        return g_sink.done;
    }

    /// Reads back the live sink state natively (volume + mute).
    pub fn readSink(self: *Backend) ?struct { pct: u8, muted: bool } {
        g_op_index = self.index;
        g_sink = .{};
        _ = runOp(issueSinkByIndex, &g_sink.done, 300);
        if (!g_sink.found) return null;
        self.muted = g_sink.muted;
        return .{ .pct = g_sink.pct, .muted = g_sink.muted };
    }
};

// --- Tests (pure byte-buffer + mapping logic; no libpulse, no daemon) ---

const testing = std.testing;

test "buildCvolume builds a channels+values pa_cvolume" {
    var buf: [132]u8 = undefined;
    try testing.expect(buildCvolume(50, 2, &buf));
    try testing.expectEqual(@as(u8, 2), buf[0]);
    try testing.expectEqual(@as(u32, 32768), std.mem.readInt(u32, buf[4..8], .little));
    try testing.expectEqual(@as(u32, 32768), std.mem.readInt(u32, buf[8..12], .little));
    try testing.expect(buildCvolume(0, 1, &buf));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buf[4..8], .little));
    try testing.expect(buildCvolume(100, 1, &buf));
    try testing.expectEqual(PA_VOLUME_NORM, std.mem.readInt(u32, buf[4..8], .little));
}

test "buildCvolume clamps percent and rejects bad channel counts" {
    var buf: [132]u8 = undefined;
    try testing.expect(buildCvolume(150, 2, &buf));
    try testing.expectEqual(PA_VOLUME_NORM, std.mem.readInt(u32, buf[4..8], .little));
    try testing.expect(!buildCvolume(50, 0, &buf));
    try testing.expect(!buildCvolume(50, 64, buf[0..4]));
}

test "volumePct averages channels onto the 0-100 scale" {
    var buf: [132]u8 = undefined;
    try testing.expect(buildCvolume(50, 1, &buf));
    try testing.expectEqual(@as(?u8, 50), volumePct(buf[0..132], 1));
    // Stereo average: left 100%, right 0%.
    std.mem.writeInt(u32, buf[4..8], PA_VOLUME_NORM, .little);
    std.mem.writeInt(u32, buf[8..12], 0, .little);
    try testing.expectEqual(@as(?u8, 50), volumePct(buf[0..132], 2));
}

test "parseSinkInfo extracts index/channels/muted at the pinned offsets" {
    var buf: [sink_info_muted + 8]u8 = undefined;
    @memset(&buf, 0);
    std.mem.writeInt(u32, buf[sink_info_index..][0..4], 42, .little);
    buf[sink_info_channel_bytes] = 2;
    std.mem.writeInt(i32, buf[sink_info_muted..][0..4], 1, .little);
    const snap = parseSinkInfo(&buf) orelse return error.NoSnap;
    try testing.expectEqual(@as(u32, 42), snap.index);
    try testing.expectEqual(@as(u8, 2), snap.channels);
    try testing.expect(snap.muted);

    std.mem.writeInt(i32, buf[sink_info_muted..][0..4], 0, .little);
    try testing.expectEqual(false, parseSinkInfo(&buf).?.muted);
}

test "parseSinkInfo rejects invalid or short thumbnails" {
    var buf: [sink_info_muted + 8]u8 = undefined;
    @memset(&buf, 0); // index 0 == PA_INVALID clamps to invalid
    try testing.expect(parseSinkInfo(&buf) == null);

    var short: [40]u8 = undefined;
    @memset(&short, 0);
    try testing.expect(parseSinkInfo(&short) == null);
}

test "readDefaultSink tries both version offsets" {
    const name = "alsa_output.pci-0000_00_1f.3.analog-stereo";
    var info: [256]u8 = undefined;
    @memset(&info, 0);
    const name_off = 200;
    @memcpy(info[name_off .. name_off + name.len], name);
    const ptr_val: usize = @intFromPtr(&info) + name_off;

    // 16.0+ layout: default_sink_name at 48.
    std.mem.writeInt(usize, info[48..56], ptr_val, .little);
    try testing.expectEqualStrings(name, readDefaultSink(&info).?);

    // Pre-16.0 layout: fall back to offset 40.
    std.mem.writeInt(usize, info[40..48], ptr_val, .little);
    std.mem.writeInt(usize, info[48..56], 0, .little);
    try testing.expectEqualStrings(name, readDefaultSink(&info).?);

    // Neither: null.
    std.mem.writeInt(usize, info[40..48], 0, .little);
    try testing.expect(readDefaultSink(&info) == null);
}

test "plausibleSinkName accepts real names and rejects garbage" {
    try testing.expect(plausibleSinkName("alsa_output.pci-0000_00_1f.3.analog-stereo"));
    try testing.expect(plausibleSinkName("_default"));
    try testing.expect(!plausibleSinkName(""));
    try testing.expect(!plausibleSinkName("\x01control"));
    try testing.expect(!plausibleSinkName("...dots"));
}
