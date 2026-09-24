//! Dependency-free ALSA control backend for the volume segment.
//!
//! Talks straight to the kernel's sound control interface
//! (`/dev/snd/controlC*`, `SNDRV_CTL_IOCTL_*`) with classic POSIX fds and
//! ioctls -- no libasound, no `amixer` subprocess. One commit is a single
//! ioctl syscall (microseconds, no fork/exec/pipe), which is what makes
//! per-event, un-throttled volume scrolls/drags possible on ALSA-only
//! machines (pure ALSA, no PulseAudio/PipeWire).
//!
//! Activation gate: the volume segment only attaches this backend when no
//! PulseAudio runtime is present. When PipeWire/PulseAudio is in the mix, the
//! system's default `Master` is a software mixer element (PipeWire's
//! `pipewire-alsa` softvol, range 0-65536), and writing the raw card control
//! would change a different element than the one `amixer`/`pactl` display. On
//! a pure-ALSA box the default `Master` *is* the card's `Master Playback
//! Volume` control, so a direct ioctl is byte-identical in effect to
//! `amixer set Master N%`.
//!
//! Device selection: scan `controlC0..controlC31`, enumerate each card's
//! elements (`SNDRV_CTL_IOCTL_ELEM_LIST`), and take the first MIXER-interface
//! INTEGER control named `Master Playback Volume` (falling back to `Master`)
//! that is readable and writable. The optional mute control `Master Playback
//! Switch` (BOOLEAN) is attached the same way.
//!
//! Everything below is pure kernel ABI. The structs are pinned by runtime
//! verification against the live device (sizes id=64 list=80 info=272
//! value=1224 on x86_64/aarch64/riscv64) and encode exactly the UAPI layout
//! in `include/uapi/sound/asound.h` (`SNDRV_CTL_IOCTL_ELEM_LIST/INFO/READ/
//! WRITE`); percent mapping follows `amixer`'s linear [min..max] <-> 0-100
//! scale.

const std = @import("std");
const slider = @import("slider");

const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("sys/ioctl.h");
});

const SNDRV_CTL_ELEM_IFACE_MIXER = 2;
const SNDRV_CTL_ELEM_TYPE_BOOLEAN = 1;
const SNDRV_CTL_ELEM_TYPE_INTEGER = 2;
const SNDRV_CTL_ELEM_ACCESS_WRITE: c_uint = 0x0002;
const SNDRV_CTL_ELEM_ACCESS_INACTIVE: c_uint = 0x0008;

const ElemId = extern struct {
    numid: c_uint,
    iface: c_int,
    device: c_uint,
    subdevice: c_uint,
    name: [44]u8,
    index: c_uint,

    fn matches(self: *const ElemId, name: []const u8) bool {
        if (self.iface != SNDRV_CTL_ELEM_IFACE_MIXER) return false;
        return std.mem.eql(u8, self.name[0..@min(name.len, self.name.len)], name);
    }
};

const ElemList = extern struct {
    offset: c_uint,
    space: c_uint,
    used: c_uint,
    count: c_uint,
    pids: ?*ElemId,
    reserved: [50]u8,
};

const InfoInteger = extern struct {
    min: c_long,
    max: c_long,
    step: c_long,
};

const InfoUnion = extern union {
    integer: InfoInteger,
    integer64: extern struct {
        min: i64,
        max: i64,
        step: i64,
    },
    enumerated: extern struct {
        items: c_uint,
        item: c_uint,
        name: [64]u8,
        names_ptr: u64,
        names_length: c_uint,
    },
    reserved: [128]u8,
};

const ElemInfo = extern struct {
    id: ElemId,
    type: c_int,
    access: c_uint,
    count: c_uint,
    owner: c_int,
    value: InfoUnion,
    reserved: [64]u8,
};

const ValueUnion = extern union {
    integer: [128]c_long,
    integer64: [64]i64,
    enumerated: [128]c_uint,
    bytes: [512]u8,
};

const ElemValue = extern struct {
    id: ElemId,
    indirect: c_uint,
    value: ValueUnion,
    reserved: [128]u8,
};

fn iowr(comptime typ: u8, comptime nr: u8, comptime size: usize) c_ulong {
    return (@as(c_ulong, 3) << 30) |
        (@as(c_ulong, typ) << 8) |
        @as(c_ulong, nr) |
        (@as(c_ulong, size) << 16);
}

/// Wraps the libc `ioctl` whose UAPI request arg is a signed `int`: request
/// numbers with bit 31 set (all _IOR/_IOWR) sign-extend into the kernel's
/// unsigned request, exactly as they do from C.
fn devctl(fd: c_int, request: c_ulong, ptr: anytype) c_int {
    return c.ioctl(fd, @as(c_int, @bitCast(@as(u32, @truncate(request)))), ptr);
}

const ELEM_LIST = iowr('U', 0x10, @sizeOf(ElemList));
const ELEM_INFO = iowr('U', 0x11, @sizeOf(ElemInfo));
const ELEM_READ = iowr('U', 0x12, @sizeOf(ElemValue));
const ELEM_WRITE = iowr('U', 0x13, @sizeOf(ElemValue));

/// Percentage onto the control's [min..max] scale, nearest-rounding like
/// `amixer set Master N%` (which maps 50 % of 0..87 to 44). The linear map
/// is the shared `slider.rawFromPct`.
fn rawFromPct(pct: u8, min: c_long, max: c_long) c_long {
    return slider.rawFromPct(c_long, pct, min, max);
}

/// Inverse of `rawFromPct`: raw value onto the 0-100 scale (nearest-rounding);
/// the shared `slider.pctFromRaw`.
fn pctFromRaw(raw: c_long, min: c_long, max: c_long) u8 {
    return slider.pctFromRaw(c_long, raw, min, max);
}

/// Reads the current value of element `numid` into `out` (up to `*count`
/// entries). Performs one `ELEM_READ` ioctl.
fn readElem(fd: c_int, numid: c_uint, out: []c_long) bool {
    var v = std.mem.zeroes(ElemValue);
    v.id.numid = numid;
    if (devctl(fd, ELEM_READ, &v) != 0) return false;
    @memcpy(out, v.value.integer[0..@min(out.len, v.value.integer.len)]);
    return true;
}

/// Writes `values` to element `numid`. Performs one `ELEM_WRITE` ioctl.
fn writeElem(fd: c_int, numid: c_uint, values: []const c_long) bool {
    var v = std.mem.zeroes(ElemValue);
    v.id.numid = numid;
    const n = @min(values.len, v.value.integer.len);
    @memcpy(v.value.integer[0..n], values[0..n]);
    return devctl(fd, ELEM_WRITE, &v) == 0;
}

fn elemInfo(fd: c_int, id: ElemId) ?ElemInfo {
    var info = std.mem.zeroes(ElemInfo);
    info.id = id;
    if (devctl(fd, ELEM_INFO, &info) != 0) return null;
    return info;
}

/// An attached, verified `Master Playback Volume` control.
pub const Master = struct {
    fd: c_int,
    /// Volume element numid on the control device.
    numid: c_uint,
    /// Channel count of the volume element (1 for mono, 2 for stereo).
    count: u32,
    min: c_long,
    max: c_long,
    /// `Master Playback Switch` numid; 0 when the card has no such control.
    switch_numid: c_uint,

    pub fn deinit(self: *Master) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        self.* = undefined;
    }

    /// Applies a 0-100 level to every channel of the volume control.
    pub fn setVolumePct(self: *const Master, pct: u8) bool {
        const target = rawFromPct(@min(pct, 100), self.min, self.max);
        const n = @min(@as(usize, self.count), 128);
        var values: [128]c_long = undefined;
        for (0..n) |i| values[i] = target;
        return writeElem(self.fd, self.numid, values[0..n]);
    }

    /// Reads the level as 0-100 (channel 0).
    pub fn readVolumePct(self: *const Master) ?u8 {
        var values: [128]c_long = undefined;
        if (!readElem(self.fd, self.numid, &values)) return null;
        return pctFromRaw(values[0], self.min, self.max);
    }

    /// Mutes (or unmutes) via the joined switch control.
    pub fn setMuted(self: *const Master, muted: bool) bool {
        if (self.switch_numid == 0) return false;
        const v = [_]c_long{@intFromBool(muted)};
        return writeElem(self.fd, self.switch_numid, &v);
    }

    /// Current mute state; null when no switch control or the read failed.
    pub fn readMuted(self: *const Master) ?bool {
        if (self.switch_numid == 0) return null;
        var values: [128]c_long = undefined;
        if (!readElem(self.fd, self.switch_numid, &values)) return null;
        return values[0] != 0;
    }
};

/// Largest number of elements a card scan accepts (kernel control devices
/// have far fewer; a larger card is skipped as unverifiable).
const max_elem_scan: usize = 512;

/// Scans `controlC0..controlC31` and attaches the first usable Master volume
/// control (with its optional switch). Returns null when nothing answers or
/// nothing is both MIXER-facing, INTEGER and read/write-able.
pub fn openMaster() ?Master {
    var ids: [max_elem_scan]ElemId = undefined;
    var path: [32]u8 = undefined;
    for (0..32) |card| {
        const p = std.fmt.bufPrint(&path, "/dev/snd/controlC{d}", .{card}) catch return null;
        path[p.len] = 0;
        const fd = c.open(&path, c.O_RDWR | c.O_CLOEXEC, @as(c_uint, 0));
        if (fd < 0) continue;

        var list: ElemList = .{
            .offset = 0,
            .space = 0,
            .used = 0,
            .count = 0,
            .pids = null,
            .reserved = undefined,
        };
        if (devctl(fd, ELEM_LIST, &list) != 0 or list.count == 0 or list.count > max_elem_scan) {
            _ = c.close(fd);
            continue;
        }
        list.space = list.count;
        list.pids = @ptrCast(&ids);
        if (devctl(fd, ELEM_LIST, &list) != 0) {
            _ = c.close(fd);
            continue;
        }

        var vol: ?ElemId = null;
        var sw: ?ElemId = null;
        const used = @min(list.used, @as(c_uint, list.count));
        const elems: []ElemId = ids[0..@intCast(used)];
        for (elems) |id| {
            if (id.matches("Master Playback Volume")) {
                if (vol == null) vol = id;
            } else if (id.matches("Master Playback Switch")) {
                if (sw == null) sw = id;
            }
        }
        if (vol == null) {
            for (elems) |id| {
                if (id.matches("Master")) {
                    vol = id;
                    break;
                }
            }
        }

        const vi = if (vol) |v| elemInfo(fd, v) else null;
        if (vi == null or
            vi.?.type != SNDRV_CTL_ELEM_TYPE_INTEGER or
            (vi.?.access & SNDRV_CTL_ELEM_ACCESS_WRITE) == 0 or
            (vi.?.access & SNDRV_CTL_ELEM_ACCESS_INACTIVE) != 0)
        {
            _ = c.close(fd);
            continue;
        }

        var switch_numid: c_uint = 0;
        if (sw) |s| {
            if (elemInfo(fd, s)) |si| {
                if (si.type == SNDRV_CTL_ELEM_TYPE_BOOLEAN and
                    (si.access & SNDRV_CTL_ELEM_ACCESS_WRITE) != 0 and
                    (si.access & SNDRV_CTL_ELEM_ACCESS_INACTIVE) == 0)
                {
                    switch_numid = si.id.numid;
                }
            }
        }

        return .{
            .fd = fd,
            .numid = vi.?.id.numid,
            .count = @min(vi.?.count, 128),
            .min = vi.?.value.integer.min,
            .max = vi.?.value.integer.max,
            .switch_numid = switch_numid,
        };
    }
    return null;
}

// Pure, subprocess-and-device-free tests: ABI sizes/encodings and the
// percent mapping are the only logic not already pinned by the live-device
// probe (see the module doc).
const testing = std.testing;

test "UAPI element struct sizes are the pinned ABI" {
    try testing.expectEqual(@as(usize, 64), @sizeOf(ElemId));
    try testing.expectEqual(@as(usize, 80), @sizeOf(ElemList));
    try testing.expectEqual(@as(usize, 272), @sizeOf(ElemInfo));
    try testing.expectEqual(@as(usize, 1224), @sizeOf(ElemValue));
}

test "control ioctls encode the UAPI numbers" {
    try testing.expectEqual(@as(c_ulong, 0xc0505510), ELEM_LIST);
    try testing.expectEqual(@as(c_ulong, 0xc1105511), ELEM_INFO);
    try testing.expectEqual(@as(c_ulong, 0xc4c85512), ELEM_READ);
    try testing.expectEqual(@as(c_ulong, 0xc4c85513), ELEM_WRITE);
}

test "rawFromPct maps percent linearly onto min..max" {
    // The exact range amixer reports on the probing card (0..87).
    try testing.expectEqual(@as(c_long, 44), rawFromPct(50, 0, 87));
    try testing.expectEqual(@as(c_long, 0), rawFromPct(0, 0, 87));
    try testing.expectEqual(@as(c_long, 87), rawFromPct(100, 0, 87));
    try testing.expectEqual(@as(c_long, 5), rawFromPct(1, 0, 500));
    // Softvol-style 0..65536 range.
    try testing.expectEqual(@as(c_long, 32768), rawFromPct(50, 0, 65536));
    try testing.expectEqual(@as(c_long, 65536), rawFromPct(100, 0, 65536));
}

test "pctFromRaw inverts rawFromPct" {
    // Nearest-rounding is not lossless at odd spans (like amixer's), so the
    // round-trip assertions use spans where the midpoint is exact.
    try testing.expectEqual(@as(u8, 50), pctFromRaw(rawFromPct(50, 0, 65536), 0, 65536));
    try testing.expectEqual(@as(u8, 100), pctFromRaw(87, 0, 87));
    try testing.expectEqual(@as(u8, 0), pctFromRaw(0, 0, 87));
    try testing.expectEqual(@as(u8, 51), pctFromRaw(44, 0, 87));
    // Out-of-range raw clamps.
    try testing.expectEqual(@as(u8, 100), pctFromRaw(9999, 0, 87));
}

test "pctFromRaw handles a zero or inverted range" {
    try testing.expectEqual(@as(u8, 0), pctFromRaw(50, 0, 0));
    try testing.expectEqual(@as(u8, 0), pctFromRaw(50, 10, 5));
    try testing.expectEqual(@as(c_long, 10), rawFromPct(50, 10, 10));
}
