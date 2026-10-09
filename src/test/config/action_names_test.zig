//! Action-name grammar tests: the comptime action map (void tags verbatim +
//! hand aliases), the payload-carrying spellings, the workspace verbs' 0-based
//! payload, and the exec fallbacks (plain commands, action-verb typos,
//! unresolved placeholders). Every parse runs in a per-test arena because
//! actions own heap payloads (`.exec`, sequences); the arena frees them.

const std = @import("std");
const testing = std.testing;

const action_names = @import("action_names");
const action = @import("action");

fn parse(a: std.mem.Allocator, cmd: []const u8) !action.Action {
    return action_names.parseAction(a, cmd);
}

fn expectTag(expected: std.meta.Tag(action.Action), got: action.Action) !void {
    try testing.expectEqual(expected, std.meta.activeTag(got));
}

test "void union tag names are usable verbatim" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { cmd: []const u8, tag: std.meta.Tag(action.Action) }{
        .{ .cmd = "toggle_bar_visibility", .tag = .toggle_bar_visibility },
        .{ .cmd = "close_window", .tag = .close_window },
        .{ .cmd = "reload_config", .tag = .reload_config },
        .{ .cmd = "dump_state", .tag = .dump_state },
        .{ .cmd = "all_workspaces", .tag = .all_workspaces },
        .{ .cmd = "minimize_window", .tag = .minimize_window },
        .{ .cmd = "pin_window", .tag = .pin_window },
    };
    for (cases) |c| try expectTag(c.tag, try parse(a, c.cmd));
}

test "hand aliases fold onto their renamed void variants" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { cmd: []const u8, tag: std.meta.Tag(action.Action) }{
        .{ .cmd = "close", .tag = .close_window },
        .{ .cmd = "kill", .tag = .close_window },
        .{ .cmd = "fullscreen", .tag = .toggle_fullscreen },
        .{ .cmd = "minimize", .tag = .minimize_window },
        .{ .cmd = "prompt", .tag = .toggle_prompt },
    };
    for (cases) |c| try expectTag(c.tag, try parse(a, c.cmd));
}

test "payload aliases carry their enum payload" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    switch (try parse(a, "toggle_layout")) {
        .cycle_layout => |d| try testing.expectEqual(action.Dir.forward, d),
        else => return error.TestUnexpectedResult,
    }
    switch (try parse(a, "toggle_layout_reverse")) {
        .cycle_layout => |d| try testing.expectEqual(action.Dir.reverse, d),
        else => return error.TestUnexpectedResult,
    }
    switch (try parse(a, "increase_master")) {
        .set_master_width => |d| try testing.expectEqual(action.Dir.forward, d),
        else => return error.TestUnexpectedResult,
    }
    switch (try parse(a, "decrease_master")) {
        .set_master_width => |d| try testing.expectEqual(action.Dir.reverse, d),
        else => return error.TestUnexpectedResult,
    }
    switch (try parse(a, "swap_master_focus_swap")) {
        .swap_master => |m| try testing.expectEqual(action.SwapMode.focus_swap, m),
        else => return error.TestUnexpectedResult,
    }
    switch (try parse(a, "unminimize_fifo")) {
        .unminimize => |o| try testing.expectEqual(action.RestoreOrder.fifo, o),
        else => return error.TestUnexpectedResult,
    }
    switch (try parse(a, "scroll_view_left")) {
        .scroll_view => |d| try testing.expectEqual(action.Dir.reverse, d),
        else => return error.TestUnexpectedResult,
    }
}

test "workspace verbs parse NAME_N into a 0-based payload" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    switch (try parse(a, "workspace_1")) {
        .switch_workspace => |ws| try testing.expectEqual(@as(u8, 0), ws),
        else => return error.TestUnexpectedResult,
    }
    switch (try parse(a, "workspace_3")) {
        .switch_workspace => |ws| try testing.expectEqual(@as(u8, 2), ws),
        else => return error.TestUnexpectedResult,
    }
    switch (try parse(a, "move_to_workspace_2")) {
        .move_to_workspace => |ws| try testing.expectEqual(@as(u8, 1), ws),
        else => return error.TestUnexpectedResult,
    }
    switch (try parse(a, "toggle_tag_4")) {
        .toggle_tag => |ws| try testing.expectEqual(@as(u8, 3), ws),
        else => return error.TestUnexpectedResult,
    }
}

test "workspace verbs below 1 fall back to exec (typo warn path)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `workspace_0` starts with a known verb stem but parses to no workspace:
    // the fallback is exec, and the bare-word check warns about the likely typo.
    switch (try parse(a, "workspace_0")) {
        .exec => |cmd| try testing.expectEqualStrings("workspace_0", cmd),
        else => return error.TestUnexpectedResult,
    }
}

test "unknown bare words become exec verbatim" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "firefox", "/usr/bin/emacs", "ls -la /tmp" }) |cmd| {
        switch (try parse(a, cmd)) {
            .exec => |payload| try testing.expectEqualStrings(cmd, payload),
            else => return error.TestUnexpectedResult,
        }
    }
}

test "action-verb typos exec (with the warning), never silently drop" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Both start with a known verb stem but match no action name exactly.
    for ([_][]const u8{ "toggle_barr", "focus_next_windo" }) |cmd| {
        switch (try parse(a, cmd)) {
            .exec => |payload| try testing.expectEqualStrings(cmd, payload),
            else => return error.TestUnexpectedResult,
        }
    }
}

test "unresolved {placeholder} fragments exec verbatim, never crash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Defensive guard: the hoisted {kill} substitution in binds.zig runs first,
    // so a placeholder reaching parseAction directly only warns and execs.
    switch (try parse(a, "{kill} foo")) {
        .exec => |payload| try testing.expectEqualStrings("{kill} foo", payload),
        else => return error.TestUnexpectedResult,
    }
}

test "auto_terminal resolves to a non-empty exec payload" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The literal depends on the host PATH probe (cached per process), so the
    // pin is the shape: an exec whose payload is the probed terminal name.
    switch (try parse(a, "auto_terminal")) {
        .exec => |payload| try testing.expect(payload.len > 0),
        else => return error.TestUnexpectedResult,
    }
}
