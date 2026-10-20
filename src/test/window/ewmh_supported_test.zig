//! Display-free audit of `_NET_SUPPORTED`.
//!
//! WHY THIS EXISTS
//!   `requests.supported_atoms` is a promise to clients: every atom listed
//!   here tells pagers, taskbars, and toolkits "this WM implements this
//!   hint." Advertising an atom whose requests hana ignores is worse than
//!   omitting it -- the client builds UI around the promise and the clicks
//!   land in a warn-once-ignored branch. This file is the behavioural half
//!   of the narrow policy: it pins the advertised set against a table of
//!   claims, each claim naming the site that honours the atom, and pins the
//!   known-unimplemented hints as ABSENT. The wiring half (the property
//!   round-trips on the root) is the X-gated test in `ewmh_test.zig`.
//!
//! HOW TO STAY GREEN
//!   Adding an atom to `supported_atoms` without adding a `where` claim here
//!   fails `advertised implies handled`; adding a claim without a real
//!   handling site is a lie the next reader can see. If a hint gains real
//!   support, move it from `unhandled` to `handled` in the same change that
//!   implements it.

const std = @import("std");
const requests = @import("requests");

/// Every advertised atom, paired with the site that honours it. The claim is
/// prose, not a link -- the point is that a reviewer can find the handling
/// and that the table is the same length as `supported_atoms`.
const handled = [_]struct { name: []const u8, where: []const u8 }{
    .{ .name = "_NET_SUPPORTED", .where = "requests.zig advertiseEwmhSupport" },
    .{ .name = "_NET_SUPPORTING_WM_CHECK", .where = "requests.zig supporting_wm_check" },
    .{ .name = "_NET_WM_NAME", .where = "window_facts.zig / window.zig title reads" },
    .{ .name = "_NET_WM_STATE", .where = "client_events.zig state branch + sink merge" },
    .{ .name = "_NET_WM_STATE_FULLSCREEN", .where = "client_events.zig / fullscreen.zig" },
    .{ .name = "_NET_WM_PID", .where = "admission.zig pid prop query" },
    .{ .name = "_NET_CLOSE_WINDOW", .where = "client_events.zig -> window.closeViaProtocol (icccm.zig)" },
    .{ .name = "_NET_CURRENT_DESKTOP", .where = "client_events.zig -> switchWorkspace hook" },
    .{ .name = "_NET_WM_DESKTOP", .where = "client_events.zig -> moveToWorkspace hook" },
};

/// Hints hana does NOT implement. Advertising any of these would be a lie;
/// they must stay out of `supported_atoms`. See the gap list on
/// `requests.supported_atoms` for the reasoning per group.
const unhandled = [_][]const u8{
    // States hana neither applies nor stacks for.
    "_NET_WM_STATE_ABOVE",
    "_NET_WM_STATE_STICKY",
    "_NET_WM_STATE_HIDDEN",
    "_NET_WM_STATE_DEMANDS_ATTENTION",
    // Client-message request answered only with a warning-and-ignore
    // (_NET_CLOSE_WINDOW/_NET_CURRENT_DESKTOP/_NET_WM_DESKTOP used to sit
    // here too; they are implemented now and advertised above).
    "_NET_ACTIVE_WINDOW",
    // Action/type/strut hints: declared on the bar's own window as a client,
    // never read for managed windows.
    "_NET_WM_ALLOWED_ACTIONS",
    "_NET_WM_ACTION_CLOSE",
    "_NET_WM_ACTION_ABOVE",
    "_NET_WM_ACTION_STICK",
    "_NET_WM_WINDOW_TYPE",
    "_NET_WM_WINDOW_TYPE_DOCK",
    "_NET_WM_STRUT_PARTIAL",
    // Enumeration hana does not maintain.
    "_NET_CLIENT_LIST",
    "_NET_CLIENT_LIST_STACKING",
};

test "advertised implies handled: every supported_atom has a handling claim" {
    try std.testing.expectEqual(requests.supported_atoms.len, handled.len);
    for (requests.supported_atoms) |name| {
        var found = false;
        for (handled) |claim| {
            if (std.mem.eql(u8, claim.name, name)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "unimplemented hints stay off _NET_SUPPORTED" {
    for (unhandled) |name| {
        for (requests.supported_atoms) |advertised| {
            try std.testing.expect(!std.mem.eql(u8, advertised, name));
        }
    }
}

test "core client promise: _NET_WM_STATE_FULLSCREEN is advertised" {
    // GLFW/LWJGL only fullscreen via EWMH when this atom is listed; dropping
    // it would push Minecraft-class apps back into the override-redirect
    // fallback this list exists to avoid.
    var present = false;
    for (requests.supported_atoms) |name| {
        if (std.mem.eql(u8, name, "_NET_WM_STATE_FULLSCREEN")) present = true;
    }
    try std.testing.expect(present);
}
