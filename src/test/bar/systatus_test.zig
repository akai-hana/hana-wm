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

// --- per-readout parsers -------------------------------------------------
//
// These live in the readout FILES (cpu.zig / ram.zig / batt.zig), not in the
// systatus core, and they are tested from here rather than inline because this
// build only ever runs `*_test` module roots: a `test` block inside an
// ordinary module is never compiled, so the inline test ram.zig used to carry
// was dead code. Importing the concrete readouts here is safe against the
// deletion matrix because that matrix runs `zig build` (exe only) and never
// the test step; `zig build test` only runs in the full tree.
const cpu = @import("cpu");
const ram = @import("ram");
const batt = @import("batt");

test "parseCpuLine sums the fields and pairs idle with iowait" {
    const sample = cpu.parseCpuLine("cpu  100 20 30 400 50 0 0 0 0 0\ncpu0 1 1 1\n").?;
    try std.testing.expectEqual(@as(u64, 600), sample.total);
    try std.testing.expectEqual(@as(u64, 450), sample.idle);
}

test "parseCpuLine without an iowait column still parses" {
    const sample = cpu.parseCpuLine("cpu  10 20 30 40\n").?;
    try std.testing.expectEqual(@as(u64, 100), sample.total);
    try std.testing.expectEqual(@as(u64, 40), sample.idle);
}

test "parseCpuLine rejects a per-core line and malformed fields" {
    try std.testing.expectEqual(@as(?cpu.Sample, null), cpu.parseCpuLine("cpu0 1 2 3 4\n"));
    try std.testing.expectEqual(@as(?cpu.Sample, null), cpu.parseCpuLine("cpu  1 x 3 4\n"));
    try std.testing.expectEqual(@as(?cpu.Sample, null), cpu.parseCpuLine(""));
}

test "utilBetween reports busy percent over the interval" {
    const a: cpu.Sample = .{ .total = 100, .idle = 60 };
    const b: cpu.Sample = .{ .total = 200, .idle = 80 };
    // 100 jiffies elapsed, 20 of them idle -> 80% busy.
    try std.testing.expectEqual(@as(?u8, 80), cpu.utilBetween(a, b));
}

test "utilBetween returns null with no previous sample" {
    const b: cpu.Sample = .{ .total = 200, .idle = 80 };
    // The arm-frame case: no interval yet, so no reading -- NOT the
    // boot-cumulative average that used to paint a bogus one-frame "CPU 4%".
    try std.testing.expectEqual(@as(?u8, null), cpu.utilBetween(null, b));
}

test "utilBetween returns null when the counters rewind" {
    const a: cpu.Sample = .{ .total = 1000, .idle = 600 };
    const b: cpu.Sample = .{ .total = 5, .idle = 1 };
    // VM suspend: the kernel restarts its counters, so there is no interval.
    try std.testing.expectEqual(@as(?u8, null), cpu.utilBetween(a, b));
}

test "utilBetween reports 0 for a fully idle interval" {
    const a: cpu.Sample = .{ .total = 100, .idle = 100 };
    const b: cpu.Sample = .{ .total = 200, .idle = 200 };
    try std.testing.expectEqual(@as(?u8, 0), cpu.utilBetween(a, b));
}

test "parseRamField extracts the value" {
    const s = "MemTotal:       16299896 kB\nMemAvailable:    12345678 kB\nMemFree:          111 kB\n";
    try std.testing.expectEqual(@as(?u64, 16299896), ram.parseRamField(s, "MemTotal:"));
    try std.testing.expectEqual(@as(?u64, 12345678), ram.parseRamField(s, "MemAvailable:"));
    try std.testing.expectEqual(@as(?u64, null), ram.parseRamField(s, "SwapTotal:"));
}

test "usedPct computes the used fraction" {
    try std.testing.expectEqual(@as(?u8, 24), ram.usedPct(16299896, 12345678));
    try std.testing.expectEqual(@as(?u8, 100), ram.usedPct(100, 0));
    try std.testing.expectEqual(@as(?u8, 0), ram.usedPct(100, 100));
}

test "usedPct clamps when available exceeds total" {
    // The kernel can report more available than total on a busy machine; the
    // saturating subtract and the clamp keep that off the bar as 101%.
    try std.testing.expectEqual(@as(?u8, 0), ram.usedPct(100, 150));
}

test "usedPct refuses a zero total" {
    try std.testing.expectEqual(@as(?u8, null), ram.usedPct(0, 0));
}

test "parseCapacity trims, parses and range-checks" {
    try std.testing.expectEqual(@as(?u8, 87), batt.parseCapacity("87\n"));
    try std.testing.expectEqual(@as(?u8, 0), batt.parseCapacity(" 0 \n"));
    try std.testing.expectEqual(@as(?u8, 100), batt.parseCapacity("100\n"));
    // Out of range is rejected rather than painted as a level.
    try std.testing.expectEqual(@as(?u8, null), batt.parseCapacity("101\n"));
    try std.testing.expectEqual(@as(?u8, null), batt.parseCapacity("255\n"));
    try std.testing.expectEqual(@as(?u8, null), batt.parseCapacity(""));
    try std.testing.expectEqual(@as(?u8, null), batt.parseCapacity("abc\n"));
}
