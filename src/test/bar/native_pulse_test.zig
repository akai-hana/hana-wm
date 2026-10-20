//! Test module for the runtime-dlopen PulseAudio backend.
//!
//! The pure buffer-mapping/offset-guard/cvolume logic lives HERE, not in
//! native_pulse.zig: an inline test in an imported module is never analyzed by
//! this harness.
//!
//! Attach/read/commit need libpulse.so.0 and a live daemon, so they are
//! runtime-verified on real machines instead.

const std = @import("std");
const native_pulse = @import("native_pulse");

const testing = std.testing;

test "native_pulse.buildCvolume builds a channels+values pa_cvolume" {
    var buf: [132]u8 = undefined;
    try std.testing.expect(native_pulse.buildCvolume(50, 2, &buf));
    try std.testing.expectEqual(@as(u8, 2), buf[0]);
    try std.testing.expectEqual(@as(u32, 32768), std.mem.readInt(u32, buf[4..8], .little));
    try std.testing.expectEqual(@as(u32, 32768), std.mem.readInt(u32, buf[8..12], .little));
    try std.testing.expect(native_pulse.buildCvolume(0, 1, &buf));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buf[4..8], .little));
    try std.testing.expect(native_pulse.buildCvolume(100, 1, &buf));
    try std.testing.expectEqual(native_pulse.PA_VOLUME_NORM, std.mem.readInt(u32, buf[4..8], .little));
}

test "native_pulse.buildCvolume clamps percent and rejects bad channel counts" {
    var buf: [132]u8 = undefined;
    try std.testing.expect(native_pulse.buildCvolume(150, 2, &buf));
    try std.testing.expectEqual(native_pulse.PA_VOLUME_NORM, std.mem.readInt(u32, buf[4..8], .little));
    try std.testing.expect(!native_pulse.buildCvolume(50, 0, &buf));
    try std.testing.expect(!native_pulse.buildCvolume(50, 64, buf[0..4]));
}

test "native_pulse.volumePct averages channels onto the 0-100 scale" {
    var buf: [132]u8 = undefined;
    try std.testing.expect(native_pulse.buildCvolume(50, 1, &buf));
    try std.testing.expectEqual(@as(?u8, 50), native_pulse.volumePct(buf[0..132], 1));
    // Stereo average: left 100%, right 0%.
    std.mem.writeInt(u32, buf[4..8], native_pulse.PA_VOLUME_NORM, .little);
    std.mem.writeInt(u32, buf[8..12], 0, .little);
    try std.testing.expectEqual(@as(?u8, 50), native_pulse.volumePct(buf[0..132], 2));
}

test "native_pulse.parseSinkInfo extracts index/channels/muted at the pinned offsets" {
    var buf: [native_pulse.sink_info_muted + 8]u8 = undefined;
    @memset(&buf, 0);
    std.mem.writeInt(u32, buf[native_pulse.sink_info_index..][0..4], 42, .little);
    buf[native_pulse.sink_info_channel_bytes] = 2;
    std.mem.writeInt(i32, buf[native_pulse.sink_info_muted..][0..4], 1, .little);
    const snap = native_pulse.parseSinkInfo(&buf) orelse return error.NoSnap;
    try std.testing.expectEqual(@as(u32, 42), snap.index);
    try std.testing.expectEqual(@as(u8, 2), snap.channels);
    try std.testing.expect(snap.muted);

    std.mem.writeInt(i32, buf[native_pulse.sink_info_muted..][0..4], 0, .little);
    try std.testing.expectEqual(false, native_pulse.parseSinkInfo(&buf).?.muted);
}

test "native_pulse.parseSinkInfo rejects invalid or short thumbnails" {
    var buf: [native_pulse.sink_info_muted + 8]u8 = undefined;
    @memset(&buf, 0); // index 0 == PA_INVALID clamps to invalid
    try std.testing.expect(native_pulse.parseSinkInfo(&buf) == null);

    var short: [40]u8 = undefined;
    @memset(&short, 0);
    try std.testing.expect(native_pulse.parseSinkInfo(&short) == null);
}

test "native_pulse.readDefaultSink tries both version offsets" {
    const name = "alsa_output.pci-0000_00_1f.3.analog-stereo";
    var info: [256]u8 = undefined;
    @memset(&info, 0);
    const name_off = 200;
    @memcpy(info[name_off .. name_off + name.len], name);
    const ptr_val: usize = @intFromPtr(&info) + name_off;

    // 16.0+ layout: default_sink_name at 48.
    std.mem.writeInt(usize, info[48..56], ptr_val, .little);
    try std.testing.expectEqualStrings(name, native_pulse.readDefaultSink(&info).?);

    // Pre-16.0 layout: fall back to offset 40.
    std.mem.writeInt(usize, info[40..48], ptr_val, .little);
    std.mem.writeInt(usize, info[48..56], 0, .little);
    try std.testing.expectEqualStrings(name, native_pulse.readDefaultSink(&info).?);

    // Neither: null.
    std.mem.writeInt(usize, info[40..48], 0, .little);
    try std.testing.expect(native_pulse.readDefaultSink(&info) == null);
}

test "native_pulse.plausibleSinkName accepts real names and rejects garbage" {
    try std.testing.expect(native_pulse.plausibleSinkName("alsa_output.pci-0000_00_1f.3.analog-stereo"));
    try std.testing.expect(native_pulse.plausibleSinkName("_default"));
    try std.testing.expect(!native_pulse.plausibleSinkName(""));
    try std.testing.expect(!native_pulse.plausibleSinkName("\x01control"));
    try std.testing.expect(!native_pulse.plausibleSinkName("...dots"));
}

test "native_pulse.commitVerdict: timeout is optimistic, a completed wait defers to the daemon" {
    // The P2-61/D21 rule: a timed-out commit wait reports success so the
    // display updates now and the 5 s read reconciles -- a wedged daemon must
    // not stall the event loop for the full deadline on every scroll tick.
    try std.testing.expect(native_pulse.commitVerdict(false, false));
    try std.testing.expect(native_pulse.commitVerdict(false, true));
    // A wait that DID complete defers to the daemon's verdict: a rejection
    // (done with found=false) must never read as applied.
    try std.testing.expect(!native_pulse.commitVerdict(true, false));
    try std.testing.expect(native_pulse.commitVerdict(true, true));
}
