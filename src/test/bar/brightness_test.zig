//! Unit tests for the brightness slider sub's sysfs I/O against a fabricated
//! `/class/backlight/<dev>/` tree in a temp dir -- no host backlight is ever
//! touched. The pure scale/offset/format helpers live as inline tests inside
//! brightness.zig -- an inline test in an imported module is never analyzed by
//! this harness, so those five were dead; they are recovered below alongside
//! the file-backed read/write and device-resolution paths.

// (28.6) Declared here, next to the imports that make it necessary, rather than in a
// build.zig table that had to be kept in agreement with them by hand.
// build-gate: seg_brightness

const std = @import("std");
const brightness = @import("brightness");
const slider = @import("slider");
const types = @import("types");

const io = std.testing.io;

/// Writes a sysfs-shaped attribute file under the temp root.
fn writeAttr(root: std.Io.Dir, comptime class: []const u8, dev: []const u8, comptime attr: []const u8, data: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&buf, "class/{s}/{s}", .{ class, dev });
    const rel = try std.fmt.bufPrint(&buf, "class/{s}/{s}/{s}", .{ class, dev, attr });
    try root.createDirPath(io, dir_path);
    try root.writeFile(io, .{ .sub_path = rel, .data = data });
}

/// The 25.3 span form: `Label` carries `value_start`/`value_len` rather than a
/// subslice, so assertions spell the comparison out instead of relying on a
/// `?[]const u8` field these tests used to have.
fn valueSpan(l: slider.Label) []const u8 {
    return l.text[l.value_start..][0..l.value_len];
}

test "readPctFrom reads the commit node and normalizes it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // `brightness` (the commit node) is preferred over `actual_brightness`;
    // both are present to pin that preference.
    try writeAttr(tmp.dir, "backlight", "test", "max_brightness", "1000\n");
    try writeAttr(tmp.dir, "backlight", "test", "actual_brightness", "240\n");
    try writeAttr(tmp.dir, "backlight", "test", "brightness", "250\n");

    var base: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(io, &base);
    const base_path = base[0..base_len];

    try std.testing.expectEqual(@as(?u8, 25), brightness.readPctFrom(base_path, .backlight, "test"));
}

test "readPctFrom falls back to actual_brightness when brightness is absent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeAttr(tmp.dir, "backlight", "test", "max_brightness", "1000\n");
    try writeAttr(tmp.dir, "backlight", "test", "actual_brightness", "240\n");

    var base: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(io, &base);
    const base_path = base[0..base_len];

    try std.testing.expectEqual(@as(?u8, 24), brightness.readPctFrom(base_path, .backlight, "test"));
}

test "readPctFrom returns null for missing or zero-max devices" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeAttr(tmp.dir, "backlight", "empty", "max_brightness", "0\n");
    try writeAttr(tmp.dir, "backlight", "empty", "brightness", "0\n");

    var base: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(io, &base);
    const base_path = base[0..base_len];

    try std.testing.expectEqual(@as(?u8, null), brightness.readPctFrom(base_path, .backlight, "nope"));
    try std.testing.expectEqual(@as(?u8, null), brightness.readPctFrom(base_path, .backlight, "empty"));
}

test "applyPctTo writes the raw value derived from the percent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeAttr(tmp.dir, "backlight", "test", "max_brightness", "1000\n");
    try writeAttr(tmp.dir, "backlight", "test", "brightness", "0\n");

    var base: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(io, &base);
    const base_path = base[0..base_len];

    try std.testing.expectEqual(brightness.WriteResult.ok, brightness.applyPctTo(base_path, .backlight, "test", 50));

    var buf: [16]u8 = undefined;
    const f = try tmp.dir.openFile(io, "class/backlight/test/brightness", .{});
    defer f.close(io);
    const n = f.readPositionalAll(io, &buf, 0) catch return error.ReadFailed;
    const txt = std.mem.trim(u8, buf[0..n], " \n\r");
    try std.testing.expectEqualStrings("500", txt);

    try std.testing.expectEqual(@as(?u8, 50), brightness.readPctFrom(base_path, .backlight, "test"));
}

test "applyPctTo clamps percent to 100" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeAttr(tmp.dir, "backlight", "test", "max_brightness", "1000\n");
    try writeAttr(tmp.dir, "backlight", "test", "brightness", "0\n");

    var base: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(io, &base);
    const base_path = base[0..base_len];

    try std.testing.expectEqual(brightness.WriteResult.ok, brightness.applyPctTo(base_path, .backlight, "test", 200));
    try std.testing.expectEqual(@as(?u8, 100), brightness.readPctFrom(base_path, .backlight, "test"));
}

test "applyPctTo reports transient for a missing device" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(io, &base);
    const base_path = base[0..base_len];
    try std.testing.expectEqual(brightness.WriteResult.transient, brightness.applyPctTo(base_path, .backlight, "nope", 50));
}

test "findDevice picks the lexicographically smallest usable backlight" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // zzz is valid but not the smallest; aaa is the winner; broken is skipped.
    try writeAttr(tmp.dir, "backlight", "zzz", "max_brightness", "10\n");
    try writeAttr(tmp.dir, "backlight", "zzz", "brightness", "5\n");
    try writeAttr(tmp.dir, "backlight", "aaa", "max_brightness", "100\n");
    try writeAttr(tmp.dir, "backlight", "aaa", "brightness", "50\n");
    try writeAttr(tmp.dir, "backlight", "broken", "max_brightness", "0\n");
    try writeAttr(tmp.dir, "backlight", "broken", "brightness", "0\n");

    var base: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(io, &base);
    const base_path = base[0..base_len];

    var cls: brightness.Class = .backlight;
    var dev: [64]u8 = undefined;
    const n = brightness.findDevice(base_path, "", &cls, &dev) orelse return error.NoDevice;
    try std.testing.expectEqualStrings("aaa", dev[0..n]);
    try std.testing.expect(brightness.readPctFrom(base_path, cls, dev[0..n]).? == 50);
}

test "findDevice honors an explicit backlight pin" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeAttr(tmp.dir, "backlight", "aaa", "max_brightness", "100\n");
    try writeAttr(tmp.dir, "backlight", "aaa", "brightness", "50\n");
    try writeAttr(tmp.dir, "backlight", "zzz", "max_brightness", "10\n");
    try writeAttr(tmp.dir, "backlight", "zzz", "brightness", "5\n");

    var base: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(io, &base);
    const base_path = base[0..base_len];

    var cls: brightness.Class = .backlight;
    var dev: [64]u8 = undefined;
    const n = brightness.findDevice(base_path, "zzz", &cls, &dev) orelse return error.NoDevice;
    try std.testing.expectEqualStrings("zzz", dev[0..n]);
    try std.testing.expect(cls == .backlight);
}

test "findDevice pin falls back to the scan when the pin is unusable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeAttr(tmp.dir, "backlight", "aaa", "max_brightness", "100\n");
    try writeAttr(tmp.dir, "backlight", "aaa", "brightness", "50\n");

    var base: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(io, &base);
    const base_path = base[0..base_len];

    var cls: brightness.Class = .backlight;
    var dev: [64]u8 = undefined;
    const n = brightness.findDevice(base_path, "led:no-such-led", &cls, &dev) orelse return error.NoDevice;
    try std.testing.expectEqualStrings("aaa", dev[0..n]);
}

test "findDevice resolves an led-prefixed pin to the LED class" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeAttr(tmp.dir, "leds", "kbd", "max_brightness", "255\n");
    try writeAttr(tmp.dir, "leds", "kbd", "brightness", "128\n");

    var base: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(io, &base);
    const base_path = base[0..base_len];

    var cls: brightness.Class = .backlight;
    var dev: [64]u8 = undefined;
    const n = brightness.findDevice(base_path, "led:kbd", &cls, &dev) orelse return error.NoDevice;
    try std.testing.expectEqualStrings("kbd", dev[0..n]);
    try std.testing.expect(cls == .leds);
    try std.testing.expectEqual(@as(?u8, 50), brightness.readPctFrom(base_path, cls, dev[0..n]));
    try std.testing.expectEqual(brightness.WriteResult.ok, brightness.applyPctTo(base_path, cls, dev[0..n], 25));
    try std.testing.expectEqual(@as(?u8, 25), brightness.readPctFrom(base_path, cls, dev[0..n]));
}

// ---------------------------------------------------------------------------
// Recovered dead tests. These lived INLINE in brightness.zig and had never once
// executed: the harness runs tests from the test root, and nothing imported
// brightness.zig. The build still type-checked it, so a mutation there read as a
// kill. They now run for the first time. `label` reads module-private display
// state, so they set it through the explicit `setDisplayForTest` seam.

// helpers. The file-backed read/write round trips live in the dedicated
// brightness_test module, which fabricates a sysfs tree in a temp dir.
const testing = std.testing;

test "pctFromRaw maps raw onto the 0-100 scale" {
    try std.testing.expectEqual(@as(?u8, 75), brightness.pctFromRaw(49151, 65535));
    try std.testing.expectEqual(@as(?u8, 0), brightness.pctFromRaw(0, 100));
    try std.testing.expectEqual(@as(?u8, 100), brightness.pctFromRaw(100, 100));
    try std.testing.expectEqual(@as(?u8, null), brightness.pctFromRaw(50, 0));
}

test "rawFromPct maps percent back onto the raw scale" {
    try std.testing.expectEqual(@as(u32, 65535), brightness.rawFromPct(100, 65535));
    try std.testing.expectEqual(@as(u32, 0), brightness.rawFromPct(0, 65535));
    try std.testing.expectEqual(@as(u32, 32768), brightness.rawFromPct(50, 65535));
    try std.testing.expectEqual(@as(u32, 15), brightness.rawFromPct(100, 15));
    try std.testing.expectEqual(@as(u32, 0), brightness.rawFromPct(1, 15));
}

test "rawFromPct round-trips through pctFromRaw" {
    try std.testing.expectEqual(@as(?u8, 50), brightness.pctFromRaw(brightness.rawFromPct(50, 255), 255));
    try std.testing.expectEqual(@as(?u8, 24), brightness.pctFromRaw(brightness.rawFromPct(24, 1000), 1000));
}

test "label honors configuration" {
    var cfg = types.BarConfig{};
    cfg.brightness_format = "Level {pct}";
    var buf: [128]u8 = undefined;
    brightness.setDisplayForTest(42);
    // The seam writes a module global shared by the whole test binary:
    // restore the neutral 0 so test order never becomes load-bearing.
    defer brightness.setDisplayForTest(0);
    try std.testing.expectEqualStrings("Level 42", brightness.label(cfg, &buf).text);
    try std.testing.expectEqualStrings("42", valueSpan(brightness.label(cfg, &buf)));
}

test "label default format" {
    var buf: [128]u8 = undefined;
    brightness.setDisplayForTest(33);
    defer brightness.setDisplayForTest(0);
    try std.testing.expectEqualStrings("BRT 33%", brightness.label(types.BarConfig{}, &buf).text);
    try std.testing.expectEqualStrings("33%", valueSpan(brightness.label(types.BarConfig{}, &buf)));
}
