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

/// Parses a sysfs `capacity` file into a charge percent, rejecting anything
/// out of range rather than letting a nonsense kernel value reach the bar.
/// Pure, so the trim/parse/range rules are testable without a battery.
pub fn parseCapacity(contents: []const u8) ?u8 {
    const v = std.fmt.parseUnsigned(u8, std.mem.trim(u8, contents, " \n"), 10) catch return null;
    if (v > 100) return null;
    return v;
}

/// Charge % of the first present battery under /sys/class/power_supply.
fn read() ?u8 {
    for (0..battery_probe_slots) |i| {
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/sys/class/power_supply/BAT{d}/capacity", .{i}) catch return null;
        var cb: [16]u8 = undefined;
        const r = systatus.readFileChecked(path, &cb) orelse continue;
        if (r.truncated) continue;
        // An unreadable/invalid slot is not fatal: try the next battery, and
        // only report absence once every probed slot has come up empty.
        if (parseCapacity(r.bytes)) |v| return v;
    }
    return null;
}

/// This readout's binding to the systatus surface (`systatus.Sub`).
pub const sub: systatus.Sub = .{
    .name = "batt",
    .label = "BAT",
    .read = read,
};
