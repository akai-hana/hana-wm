//! Registry-agnostic unit tests for the systatus per-readout segment binding.
//! The `subs` registry is build-generated from file presence (build.zig's
//! buildSubsRegistryModule), and each readout is promoted to its OWN standalone
//! bar segment (`segmentFor(i)`, indexed identically to `subs[i]`), so no
//! concrete readout name ("cpu", "batt", ...) is ever hardcoded here: pinning
//! one would make the suite fail the moment a readout file is added or removed
//! -- precisely the open-module churn this surface is designed to absorb.

const std = @import("std");
const systatus = @import("systatus");

test "segmentFor promotes every readout to a distinct, non-interactive segment" {
    // One segment per readout, named after it, in the same order as `subs`
    // (build.zig emits `segmentFor(i)` for `i` == the sub's registry index,
    // so the bar's `[bar.layout.*]`.segments resolution lands on subs[i]).
    inline for (systatus.subs, 0..) |sub, i| {
        const seg = systatus.segmentFor(i);
        try std.testing.expectEqualStrings(sub.name, seg.name);
        try std.testing.expect(!seg.clickable);
    }

    // Segment names are unique across the registry (the bar resolves segments
    // by name, so a duplicate would be ambiguous).
    var seen = std.StringHashMap(void).init(std.testing.allocator);
    defer seen.deinit();
    for (systatus.subs) |sub| {
        try std.testing.expect(!seen.contains(sub.name));
        try seen.put(sub.name, {});
    }
}

test "segmentFor wires the readout lifecycle and lean draw hooks" {
    const seg = systatus.segmentFor(0);
    // Readouts self-appoint their 2 s poll cadence and flag dirty redraws...
    try std.testing.expect(seg.pollTimeoutMs != null);
    try std.testing.expect(seg.onPollWakeup != null);
    try std.testing.expect(seg.consumeRedrawRequest != null);
    try std.testing.expect(seg.naturalWidth != null);
    try std.testing.expect(seg.draw != null);
    // ...and are deliberately not interactive: no click/scroll/drag surface.
    try std.testing.expect(!seg.clickable);
}
