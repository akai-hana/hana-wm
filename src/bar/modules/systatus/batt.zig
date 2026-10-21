//! Systatus battery readout: charge % of the first
//! /sys/class/power_supply/BAT* found. Null while no battery reports a
//! capacity, so the slot collapses to zero width rather than showing stale.

const std = @import("std");
const systatus = @import("systatus");

/// Number of `BAT*` slots probed (`BAT0`..`BAT{battery_probe_slots - 1}`):
/// exotic machines have many slots, but the probe is a handful of no-op
/// stat/opens either way.
const battery_probe_slots: usize = 8;

/// Parses a sysfs `capacity` file into a charge percent, rejecting anything
/// out of range rather than letting a nonsense kernel value reach the bar.
/// Pure, so the trim/parse/range rules are testable without a battery.
pub fn parseCapacity(contents: []const u8) ?u8 {
    const v = std.fmt.parseUnsigned(u8, std.mem.trim(u8, contents, " \n"), 10) catch return null;
    if (v > 100) return null;
    return v;
}

/// Owner state: the format scratch buffer `percentSample` writes into. No
/// loose module-level scalars.
const BattState = struct {
    num: [16]u8 = undefined,
};
var g: BattState = .{};

/// Charge % of the first present battery.
fn read() ?systatus.Sample {
    for (0..battery_probe_slots) |i| {
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/sys/class/power_supply/BAT{d}/capacity", .{i}) catch return null;
        var cb: [16]u8 = undefined;
        const r = systatus.readFileChecked(path, &cb) orelse continue;
        if (r.truncated) continue;
        // An unreadable/invalid slot is not fatal: try the next battery, and
        // report absence only once every probed slot has come up empty.
        if (parseCapacity(r.bytes)) |v| return systatus.percentSample(&g.num, v);
    }
    return null;
}

pub const sub: systatus.Sub = .{
    .name = "batt",
    .label = "BAT",
    .read = read,
};
