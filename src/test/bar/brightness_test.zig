//! Unit tests for the brightness segment's sysfs I/O against a fabricated
//! `/class/backlight/<dev>/` tree in a temp dir -- no host backlight is ever
//! touched. The pure scale/offset/format helpers live as inline tests inside
//! brightness.zig; this module covers the file-backed read/write and device
//! resolution paths that need a real (temp) filesystem.

const std = @import("std");
const brightness = @import("brightness");

const io = std.testing.io;

/// Writes a sysfs-shaped attribute file under the temp root.
fn writeAttr(root: std.Io.Dir, comptime class: []const u8, dev: []const u8, comptime attr: []const u8, data: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&buf, "class/{s}/{s}", .{ class, dev });
    const rel = try std.fmt.bufPrint(&buf, "class/{s}/{s}/{s}", .{ class, dev, attr });
    try root.createDirPath(io, dir_path);
    try root.writeFile(io, .{ .sub_path = rel, .data = data });
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

    try std.testing.expect(brightness.applyPctTo(base_path, .backlight, "test", 50));

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

    try std.testing.expect(brightness.applyPctTo(base_path, .backlight, "test", 200));
    try std.testing.expectEqual(@as(?u8, 100), brightness.readPctFrom(base_path, .backlight, "test"));
}

test "applyPctTo returns false for a missing device" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(io, &base);
    const base_path = base[0..base_len];
    try std.testing.expect(!brightness.applyPctTo(base_path, .backlight, "nope", 50));
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
    try std.testing.expect(brightness.applyPctTo(base_path, cls, dev[0..n], 25));
    try std.testing.expectEqual(@as(?u8, 25), brightness.readPctFrom(base_path, cls, dev[0..n]));
}
