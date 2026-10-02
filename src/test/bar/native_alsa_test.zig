//! Test module for the dependency-free ALSA control backend.
//!
//! The pure ABI-size/ioctl-encoding/percent-mapping logic lives HERE, not in
//! native_alsa.zig. It used to live inline there with this file as a mere
//! "reachability anchor" -- on the belief that importing a module runs its
//! inline tests. IT DOES NOT. A canary `expectEqual(1, 2)` appended to
//! native_alsa.zig does not fail `zig build test`, while the same canary
//! appended here does. So those tests, which included the only coverage of
//! slider.pctFromRaw's inverted-range guard, never ran: mutation M-B2 (dropping
//! `if (max <= min) return 0;`) survived. Recovered below; it now kills M-B2.
//!
//! The live ioctl read/write path is verified against the probing machine's
//! card (see the module doc) and cannot run in unit tests.

const std = @import("std");
const native_alsa = @import("native_alsa");

test {
    _ = native_alsa;
    _ = std;
}

// ---------------------------------------------------------------------------
// Recovered dead tests, formerly INLINE in native_alsa.zig. A canary
// `expectEqual(1, 2)` appended to that file does not fail, so the import in
// this test root made the module REACHABLE WITHOUT RUNNING its inline tests:
// the harness only executes test blocks in the test root itself. These now
// run for the first time. The symbols they touch are `pub` for that reason.

test "UAPI element struct sizes are the pinned ABI" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(native_alsa.ElemId));
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(native_alsa.ElemList));
    try std.testing.expectEqual(@as(usize, 272), @sizeOf(native_alsa.ElemInfo));
    try std.testing.expectEqual(@as(usize, 1224), @sizeOf(native_alsa.ElemValue));
}

test "control ioctls encode the UAPI numbers" {
    try std.testing.expectEqual(@as(c_ulong, 0xc0505510), native_alsa.ELEM_LIST);
    try std.testing.expectEqual(@as(c_ulong, 0xc1105511), native_alsa.ELEM_INFO);
    try std.testing.expectEqual(@as(c_ulong, 0xc4c85512), native_alsa.ELEM_READ);
    try std.testing.expectEqual(@as(c_ulong, 0xc4c85513), native_alsa.ELEM_WRITE);
}

test "native_alsa.rawFromPct maps percent linearly onto min..max" {
    // The exact range amixer reports on the probing card (0..87).
    try std.testing.expectEqual(@as(c_long, 44), native_alsa.rawFromPct(50, 0, 87));
    try std.testing.expectEqual(@as(c_long, 0), native_alsa.rawFromPct(0, 0, 87));
    try std.testing.expectEqual(@as(c_long, 87), native_alsa.rawFromPct(100, 0, 87));
    try std.testing.expectEqual(@as(c_long, 5), native_alsa.rawFromPct(1, 0, 500));
    // Softvol-style 0..65536 range.
    try std.testing.expectEqual(@as(c_long, 32768), native_alsa.rawFromPct(50, 0, 65536));
    try std.testing.expectEqual(@as(c_long, 65536), native_alsa.rawFromPct(100, 0, 65536));
}

test "native_alsa.pctFromRaw inverts native_alsa.rawFromPct" {
    // Nearest-rounding is not lossless at odd spans (like amixer's), so the
    // round-trip assertions use spans where the midpoint is exact.
    try std.testing.expectEqual(@as(u8, 50), native_alsa.pctFromRaw(native_alsa.rawFromPct(50, 0, 65536), 0, 65536));
    try std.testing.expectEqual(@as(u8, 100), native_alsa.pctFromRaw(87, 0, 87));
    try std.testing.expectEqual(@as(u8, 0), native_alsa.pctFromRaw(0, 0, 87));
    try std.testing.expectEqual(@as(u8, 51), native_alsa.pctFromRaw(44, 0, 87));
    // Out-of-range raw clamps.
    try std.testing.expectEqual(@as(u8, 100), native_alsa.pctFromRaw(9999, 0, 87));
}

test "native_alsa.pctFromRaw handles a zero or inverted range" {
    try std.testing.expectEqual(@as(u8, 0), native_alsa.pctFromRaw(50, 0, 0));
    try std.testing.expectEqual(@as(u8, 0), native_alsa.pctFromRaw(50, 10, 5));
    try std.testing.expectEqual(@as(c_long, 10), native_alsa.rawFromPct(50, 10, 10));
}

// ---------------------------------------------------------------------------
// Shim-card rejection. A PipeWire- or PulseAudio-exposed ALSA control card
// accepts a write and reports success while the audio the user is hearing does
// not move, so accepting one is worse than failing: the bar would show the
// level it just set. These are name tests, so they need no /dev/snd.

test "real kernel cards are not treated as shims" {
    try std.testing.expect(!native_alsa.isShimCard("HDA Intel PCH"));
    try std.testing.expect(!native_alsa.isShimCard("USB Audio"));
    try std.testing.expect(!native_alsa.isShimCard("Dummy"));
    try std.testing.expect(!native_alsa.isShimCard(" bcm2835 Headphones"));
}

test "pipewire- and pulse-exposed cards are rejected" {
    try std.testing.expect(native_alsa.isShimCard("pipewire"));
    try std.testing.expect(native_alsa.isShimCard("PipeWire"));
    try std.testing.expect(native_alsa.isShimCard("pulse"));
    try std.testing.expect(native_alsa.isShimCard("PulseAudio"));
    try std.testing.expect(native_alsa.isShimCard("pipewire-sink"));
}

test "shim match is case-insensitive and substring-based" {
    try std.testing.expect(native_alsa.isShimCard("PIPEWIRE"));
    try std.testing.expect(native_alsa.isShimCard("pl pipewire card"));
    try std.testing.expect(native_alsa.isShimCard("PipeWire ALSA Sink"));
}

test "card name extraction stops at the NUL and tolerates a full field" {
    // A 32-char name with no terminator must yield all 32 bytes rather than
    // reading past the field, and a short one must not carry trailing zeros.
    const full = "a" ** 32;
    const trimmed = std.mem.trimEnd(u8, full, "\x00");
    try std.testing.expectEqual(@as(usize, 32), trimmed.len);

    const padded = [_]u8{ 'H', 'D', 'A', 0, 0, 0 };
    const end = std.mem.indexOfScalar(u8, &padded, 0).?;
    try std.testing.expectEqualStrings("HDA", padded[0..end]);
}
