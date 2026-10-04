//! Action-name grammar: the comptime action map (the `Action`
//! union's void tags auto-derived, plus hand-maintained aliases,
//! shadow-checked against tag names), the workspace-scoped
//! verbs (`workspace_N`, `move_to_workspace_N`, `toggle_tag_N`),
//! the `auto_terminal` substitution, and the exec-fallback typo
//! warnings. Pure parsing -- the actions land on the Config via
//! binds.zig, and input/keybind.zig turns them into keycodes at
//! buildKeybinds time.

const std = @import("std");
const constants = @import("constants");
const fallback = @import("fallback");
const log = @import("log");
const types = @import("types");

/// Cached terminal probe. `auto_terminal` is resolved at parse time so a user
/// config gets the same substitution the embedded fallback always had -- the
/// PATH walk is a sequence of blocking exec probes, so it runs at most once
/// per process. Holds a `'static` string (see fallback.detectTerminal).
var cached_terminal: ?[]const u8 = null;

fn resolveAutoTerminal(allocator: std.mem.Allocator) ![]const u8 {
    const t = cached_terminal orelse blk: {
        const probed = fallback.detectTerminal();
        cached_terminal = probed;
        break :blk probed;
    };
    return allocator.dupe(u8, t);
}

/// Every action key, as one hand-maintained table: the `Action` union's
/// void tag names are usable verbatim (auto-derived below), and these
/// entries add the aliases / payload-carrying spellings. Adding an Action
/// union member requires only the union edit for its tag name; forgetting an
/// intended alias fails the parser's unknown-action typo detection instead
/// of silently unparsable.
const action_entries = [_]struct { key: []const u8, action: types.Action }{
    // Void-variant aliases (old tag names → renamed void variants).
    .{ .key = "close", .action = .{ .close_window = {} } },
    .{ .key = "kill", .action = .{ .close_window = {} } },
    .{ .key = "fullscreen", .action = .{ .toggle_fullscreen = {} } },
    .{ .key = "minimize", .action = .{ .minimize_window = {} } },
    .{ .key = "prompt", .action = .{ .toggle_prompt = {} } },
    // Payload variant spellings (one enum payload each).
    .{ .key = "toggle_layout", .action = .{ .cycle_layout = .forward } },
    .{ .key = "toggle_layout_reverse", .action = .{ .cycle_layout = .reverse } },
    .{ .key = "increase_master", .action = .{ .set_master_width = .forward } },
    .{ .key = "decrease_master", .action = .{ .set_master_width = .reverse } },
    .{ .key = "increase_master_count", .action = .{ .set_master_count = .forward } },
    .{ .key = "decrease_master_count", .action = .{ .set_master_count = .reverse } },
    .{ .key = "stack_top", .action = .{ .grow_stack = .forward } },
    .{ .key = "stack_bottom", .action = .{ .grow_stack = .reverse } },
    .{ .key = "swap_master", .action = .{ .swap_master = .normal } },
    .{ .key = "swap_master_focus_swap", .action = .{ .swap_master = .focus_swap } },
    .{ .key = "cycle_layout_variants", .action = .{ .cycle_variants = .forward } },
    .{ .key = "cycle_layout_variants_reverse", .action = .{ .cycle_variants = .reverse } },
    .{ .key = "cycle_variants", .action = .{ .cycle_variants = .forward } },
    .{ .key = "focus_next_window", .action = .{ .cycle_focus = .forward } },
    .{ .key = "focus_prev_window", .action = .{ .cycle_focus = .reverse } },
    .{ .key = "scroll_view_left", .action = .{ .scroll_view = .reverse } },
    .{ .key = "scroll_view_right", .action = .{ .scroll_view = .forward } },
    .{ .key = "unminimize_lifo", .action = .{ .unminimize = .lifo } },
    .{ .key = "unminimize_fifo", .action = .{ .unminimize = .fifo } },
};

const action_map: std.StaticStringMap(types.Action) = blk: {
    @setEvalBranchQuota(10000);
    const fields = @typeInfo(types.Action).@"union".fields;
    var kvs: [fields.len + action_entries.len]struct { []const u8, types.Action } = undefined;
    var n: usize = 0;
    // Void tag names auto-generated from union fields.
    for (fields) |f| {
        if (f.type == void) {
            kvs[n] = .{ f.name, @field(types.Action, f.name) };
            n += 1;
        }
    }
    // Hand entries, checked against everything already in the table.
    for (action_entries) |a| {
        for (kvs[0..n]) |kv| {
            if (std.mem.eql(u8, kv[0], a.key))
                @compileError("action key shadows a union tag name: " ++ a.key);
        }
        kvs[n] = .{ a.key, a.action };
        n += 1;
    }
    break :blk .initComptime(kvs[0..n]);
};

/// Workspace-scoped actions: one spec per base name, the single source of
/// truth shared by resolveAndParseAction (which checks glob expansion against
/// `workspace_action_bases`) and parseAction (which parses the direct
/// `NAME_N` form into a payload-bearing action via `make`).
const workspace_action_specs = [_]struct {
    base: []const u8,
    make: *const fn (u8) types.Action,
}{
    .{ .base = "workspace", .make = workspaceSwitchTo },
    .{ .base = "move_to_workspace", .make = workspaceMoveTo },
    .{ .base = "toggle_tag", .make = workspaceToggleTag },
};

fn workspaceSwitchTo(ws: u8) types.Action {
    return .{ .switch_workspace = ws };
}
fn workspaceMoveTo(ws: u8) types.Action {
    return .{ .move_to_workspace = ws };
}
fn workspaceToggleTag(ws: u8) types.Action {
    return .{ .toggle_tag = ws };
}

/// Membership set of the workspace-action base names, derived from
/// `workspace_action_specs` so the two stay in sync.
pub const workspace_action_bases = std.StaticStringMap(void).initComptime(block: {
    var kvs: [workspace_action_specs.len]struct { []const u8, void } = undefined;
    for (workspace_action_specs, 0..) |spec, i| kvs[i] = .{ spec.base, {} };
    break :block kvs;
});

fn tryParseWorkspace(command: []const u8, prefix: []const u8) ?u8 {
    if (!std.mem.startsWith(u8, command, prefix)) return null;
    const num = std.fmt.parseInt(usize, command[prefix.len..], 10) catch return null;
    if (num < 1 or num > constants.max_workspace_command_1based) return null;
    return @intCast(num - 1);
}

/// Action verb stems used to spot a keybind action that was *meant* to be one
/// of hana's built-in actions but is spelled wrong. Anything not matching one
/// of these and not containing a shell metacharacter is treated as an ordinary
/// exec command and left alone (e.g. "firefox", "foot", "/usr/bin/emacs").
const action_verb_prefixes = [_][]const u8{
    "toggle_",     "increase_", "decrease_", "grow_",      "stack_", "swap_",
    "move_",       "move_to_",  "focus_",    "close_",     "kill_",  "minimize_",
    "unminimize_", "cycle_",    "scroll_",   "workspace_", "all_",   "dump_",
    "pin_",
};

/// True when `cmd` is a bare identifier (letters, digits, underscores only,
/// nothing a real shell command would need) that starts with a known action
/// verb stem, i.e. it looks like a misspelled built-in action rather than a
/// legitimate external program.
fn looksLikeActionWord(cmd: []const u8) bool {
    if (cmd.len == 0) return false;
    for (cmd) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    for (action_verb_prefixes) |p| {
        if (std.mem.startsWith(u8, cmd, p)) return true;
    }
    return false;
}

/// True when `cmd` still carries a `{kill}` token or a `{...}` placeholder
/// fragment. After the hoisted substitution this should never be true for a
/// config action; it is a defensive guard so an unresolved placeholder can
/// never be handed to the shell verbatim.
fn hasPlaceholderFragment(cmd: []const u8) bool {
    if (std.mem.indexOf(u8, cmd, "{kill}") != null) return true;
    const lbrace = std.mem.indexOfScalar(u8, cmd, '{') orelse return false;
    return std.mem.indexOfScalarPos(u8, cmd, lbrace + 1, '}') != null;
}

pub fn parseAction(allocator: std.mem.Allocator, cmd: []const u8) !types.Action {
    if (action_map.get(cmd)) |a| return a;
    inline for (workspace_action_specs) |spec| {
        if (tryParseWorkspace(cmd, spec.base ++ "_")) |ws| return spec.make(ws);
    }
    // Resolved here, not in the fallback loader: a USER config binding
    // "auto_terminal" used to reach the shell verbatim, where it is not a
    // command, so the bind parsed fine and then silently did nothing.
    if (std.mem.eql(u8, cmd, "auto_terminal")) {
        return .{ .exec = try resolveAutoTerminal(allocator) };
    }
    // The fallback is exec so any shell command can be bound, but a bare word
    // resembling a built-in action is almost always a typo, and running it as
    // an exec (which fails or does nothing) hides the mistake, so warn.
    if (looksLikeActionWord(cmd))
        log.warn("Unrecognized action '{s}': running it as an exec command: " ++
            "check the spelling (action names are matched exactly)", .{cmd});
    // Never let an unresolved `{...}` placeholder reach the shell verbatim.
    if (hasPlaceholderFragment(cmd))
        log.warn("Action '{s}' still contains a '{{...}}' placeholder; executing it verbatim", .{cmd});
    return .{ .exec = try allocator.dupe(u8, cmd) };
}
