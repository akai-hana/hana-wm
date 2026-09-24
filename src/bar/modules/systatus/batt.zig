//! Systatus battery readout.
//! Reports the charge % of the first /sys/class/power_supply/BAT* found.
//! `read` returns null while no battery reports a capacity, so a selected
//! `batt` segment renders nothing on a battery-less machine rather than a
//! stale value (its slot collapses to zero width).

const std = @import("std");
const systatus = @import("systatus");

/// Number of `BAT*` slots probed under `/sys/class/power_supply`
/// (`BAT0`..`BAT{battery_probe_slots - 1}`): laptops with many slots are
/// exotic, but the probe is a handful of no-op stat/opens either way.
const battery_probe_slots: usize = 8;

/// Charge % of the first present battery under /sys/class/power_supply.
fn read() ?u8 {
    for (0..battery_probe_slots) |i| {
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/sys/class/power_supply/BAT{d}/capacity", .{i}) catch return null;
        var cb: [16]u8 = undefined;
        const contents = systatus.readSmallFile(path, &cb) orelse continue;
        return std.fmt.parseUnsigned(u8, std.mem.trim(u8, contents, " \n"), 10) catch continue;
    }
    return null;
}

/// This readout's binding to the systatus surface (`systatus.Sub`).
pub const sub: systatus.Sub = .{
    .name = "batt",
    .label = "Batt",
    .read = read,
};
