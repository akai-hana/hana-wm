//! Systatus battery readout.
//! Reports the charge % of the first /sys/class/power_supply/BAT* found.
//! `present` drives default-set inclusion; `read` returns null while no
//! battery reports a capacity, so an explicitly selected batt item renders
//! nothing on a battery-less machine rather than a stale value.

const std = @import("std");
const systatus = @import("systatus");

/// Whether a battery is present at all (drives the default item list).
fn present() bool {
    const io = std.Options.debug_io;
    var buf: [64]u8 = undefined;
    for (0..8) |i| {
        const name = std.fmt.bufPrint(&buf, "BAT{d}", .{i}) catch return false;
        var p: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&p, "/sys/class/power_supply/{s}", .{name}) catch return false;
        const dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch continue;
        dir.close(io);
        return true;
    }
    return false;
}

/// Charge % of the first present battery under /sys/class/power_supply.
fn read() ?u8 {
    const io = std.Options.debug_io;
    var buf: [128]u8 = undefined;
    for (0..8) |i| {
        const name = std.fmt.bufPrint(&buf, "BAT{d}", .{i}) catch return null;
        var cap_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrint(&cap_buf, "/sys/class/power_supply/{s}/capacity", .{name}) catch return null;
        const f = std.Io.Dir.openFileAbsolute(io, path, .{}) catch continue;
        defer f.close(io);
        var cb: [16]u8 = undefined;
        const en = f.readPositionalAll(io, &cb, 0) catch continue;
        return std.fmt.parseUnsigned(u8, std.mem.trim(u8, cb[0..en], " \n"), 10) catch continue;
    }
    return null;
}

/// This readout's binding to the systatus surface (`systatus.Sub`).
pub const sub: systatus.Sub = .{
    .name = "batt",
    .label = "Batt",
    .read = read,
    .present = present,
};
