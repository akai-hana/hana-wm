//! Keybind grammar: the `[binds]` parser (bind strings,
//! `{...}` glob expansion, mouse bindings, the `Mod`/`kill`
//! placeholders, `+`-linked parallel batches) and the
//! orchestration that turns a parsed value into an Action.
//! The action-name grammar itself (the comptime action map,
//! workspace verbs, `auto_terminal`, exec-fallback typo
//! warnings) lives in action_names.zig; the
//! actionFromValue/resolveElement chain below is the one
//! interleaving point between the two, so it stays here and
//! calls actions.parseAction. Pure parsing -- the bindings
//! land on the Config, and input/keybind.zig turns them into
//! keycodes at buildKeybinds time.

const std = @import("std");
const keysyms = @import("keysyms");
const log = @import("log");
const masks = @import("masks");
const parser = @import("parser");
const types = @import("types");
const action_names = @import("action_names");

/// Longest single modifier token in a bind string, after trimming.
const max_modifier_key_bytes = 16;

/// Longest keysym name the bind parser will accept raw (at that length the
/// name no longer fits a zero-terminated copy in the fixed buffer → error.KeyNameTooLong).
const max_key_name_bytes = 64;

const mod_map = std.StaticStringMap(u16).initComptime(.{
    .{ "super", masks.mod_super },
    .{ "mod4", masks.mod_super },
    .{ "alt", masks.mod_alt },
    .{ "mod1", masks.mod_alt },
    .{ "control", masks.mod_control },
    .{ "ctrl", masks.mod_control },
    .{ "shift", masks.mod_shift },
});

const mouse_button_map = std.StaticStringMap(u8).initComptime(.{
    .{ "button1", 1 }, .{ "left_click", 1 },   .{ "leftclick", 1 },
    .{ "button2", 2 }, .{ "middle_click", 2 }, .{ "middleclick", 2 },
    .{ "button3", 3 }, .{ "right_click", 3 },  .{ "rightclick", 3 },
    .{ "button4", 4 }, .{ "scroll_up", 4 },    .{ "scrollup", 4 },
    .{ "button5", 5 }, .{ "scroll_down", 5 },  .{ "scrolldown", 5 },
});

const GlobEntry = struct {
    key: []const u8,
    ws_idx: u16, // 1-based position in the expanded list; 0 when there is no glob
    owned: bool, // true when key was heap-allocated and must be freed by the caller
};

/// Maximum number of keys a single `{...}` glob may expand to. Workspace
/// indices only reach 256 (see tryParseWorkspace), and a larger glob could
/// only ever produce unreachable exec fallbacks, so expansion stops there.
const max_glob_expansion: usize = 256;

/// Wraps `key` as the single unowned GlobEntry returned when a keybind key
/// has no `{...}` glob (or an unusable one) to expand.
fn singleGlobEntry(allocator: std.mem.Allocator, key: []const u8) ![]GlobEntry {
    const e = try allocator.alloc(GlobEntry, 1);
    e[0] = .{ .key = key, .ws_idx = 0, .owned = false };
    return e;
}

/// Appends one expanded entry for a plain (non-range) comma token, enforcing
/// `max_glob_expansion`. The token is substituted verbatim into the key.
fn appendExpandedEntry(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(GlobEntry),
    prefix: []const u8,
    suffix: []const u8,
    token: []const u8,
) !void {
    if (entries.items.len >= max_glob_expansion) return;
    const k = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ prefix, token, suffix });
    try entries.append(allocator, .{ .key = k, .ws_idx = @intCast(entries.items.len + 1), .owned = true });
}

/// Expands a single-char range token (e.g. "1-4"), appending one entry per
/// char, enforcing `max_glob_expansion`. A descending range is skipped with a
/// warning rather than expanded.
fn expandRangeToken(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(GlobEntry),
    key_pattern: []const u8,
    prefix: []const u8,
    suffix: []const u8,
    t: []const u8,
) !void {
    var ch = t[0];
    const end = t[2];
    if (ch > end) {
        log.warn("Keybind glob '{s}': descending range '{c}-{c}', skipping", .{ key_pattern, ch, end });
        return;
    }
    while (ch <= end) : (ch += 1) try appendExpandedEntry(allocator, entries, prefix, suffix, &.{ch});
}

/// Expands `{...}` glob patterns in a keybind key (e.g. `Mod+{1-4,Q}` -> 5 entries,
/// comma-separated tokens and single-char ranges supported).  Workspace actions get a
/// 1-based index appended; other actions are replicated unchanged.
/// Returns a single unowned entry when no glob is present.
fn expandGlobKeys(allocator: std.mem.Allocator, key_pattern: []const u8) ![]GlobEntry {
    const lbrace = std.mem.indexOfScalar(u8, key_pattern, '{') orelse
        return singleGlobEntry(allocator, key_pattern);
    const rbrace = std.mem.indexOfScalarPos(u8, key_pattern, lbrace + 1, '}') orelse {
        log.warn("Keybind glob missing closing '}}' in '{s}', treating as literal", .{key_pattern});
        return singleGlobEntry(allocator, key_pattern);
    };
    const prefix = key_pattern[0..lbrace];
    const suffix = key_pattern[rbrace + 1 ..];
    const inner = key_pattern[lbrace + 1 .. rbrace];

    var entries: std.ArrayList(GlobEntry) = .empty;
    errdefer {
        for (entries.items) |e| if (e.owned) allocator.free(e.key);
        entries.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |token| {
        const t = std.mem.trim(u8, token, " \t");
        if (t.len == 0) continue;
        if (t.len == 3 and t[1] == '-') try expandRangeToken(allocator, &entries, key_pattern, prefix, suffix, t) else try appendExpandedEntry(allocator, &entries, prefix, suffix, t);
    }
    if (entries.items.len == 0) {
        entries.deinit(allocator);
        return singleGlobEntry(allocator, key_pattern);
    }
    return try entries.toOwnedSlice(allocator);
}

/// Substitutes the `{kill}` placeholder (FIRST, for ANY action string,
/// before the workspace-branch check and before parseAction) and parses
/// the result. Previously the substitution only ran for glob-expanded
/// workspace actions, so every ordinary `{kill} foo` bind exec'd a
/// literal, broken shell command.
fn resolveAndParseAction(
    allocator: std.mem.Allocator,
    cmd: []const u8,
    ws_idx: u16,
    kill_placeholder: ?[]const u8,
) !types.Action {
    const effective: []const u8 = if (kill_placeholder) |kp| blk: {
        if (std.mem.indexOf(u8, cmd, "{kill}") != null)
            break :blk try std.mem.replaceOwned(u8, allocator, cmd, "{kill}", kp);
        break :blk cmd;
    } else cmd;
    // Free only our own substitution; `cmd` is caller-owned when unchanged.
    defer if (effective.ptr != cmd.ptr) allocator.free(effective);
    if (ws_idx > 0 and action_names.workspace_action_bases.has(effective)) {
        const ws_str = try std.fmt.allocPrint(allocator, "{s}_{d}", .{ effective, ws_idx });
        defer allocator.free(ws_str);
        return action_names.parseAction(allocator, ws_str);
    }
    return action_names.parseAction(allocator, effective);
}

/// Resolves one `binds` value into a single Action, or null when the entry
/// should be skipped (empty array, or a value that is neither string nor
/// array). A one-element array unwraps to its sole action; a multi-element
/// array becomes a `.sequence`. Within an element a `+` links a parallel
/// batch (`[a, b + c, d]` = a, then b and c together, then d).
fn actionFromValue(
    allocator: std.mem.Allocator,
    value: parser.Value,
    ws_idx: u16,
    kill: ?[]const u8,
) !?types.Action {
    return switch (value) {
        .array => |arr| {
            const items = arr.list.items;
            if (items.len == 0) return null;
            var acts: std.ArrayList(types.Action) = .empty;
            errdefer {
                for (acts.items) |*a| a.deinit(allocator);
                acts.deinit(allocator);
            }
            for (items) |elem|
                if (elem.asScalar([]const u8)) |cmd|
                    try acts.append(allocator, try resolveElement(allocator, cmd, ws_idx, kill));
            // A non-empty array whose elements were all non-strings
            // filters down to zero actions; return null (no binding) instead
            // of a dead empty sequence.
            if (acts.items.len == 0) {
                acts.deinit(allocator);
                return null;
            }
            if (acts.items.len == 1) {
                const only = acts.items[0];
                acts.deinit(allocator);
                return only;
            }
            return .{ .sequence = try acts.toOwnedSlice(allocator) };
        },
        .string => |command| try resolveElement(allocator, command, ws_idx, kill),
        else => null,
    };
}

/// A `+` is a parallel separator only when whitespace sits on at least one
/// side, so literal plus signs in exec commands (`xdotool key ctrl+plus`)
/// are never split.
fn parallelSepAt(cmd: []const u8, i: usize) bool {
    if (cmd[i] != '+') return false;
    if (i > 0 and (cmd[i - 1] == ' ' or cmd[i - 1] == '\t')) return true;
    if (i + 1 < cmd.len and (cmd[i + 1] == ' ' or cmd[i + 1] == '\t')) return true;
    return false;
}

/// Splits `cmd` on parallel separators, appending the trimmed, non-empty
/// fragments to `out`. Slices alias `cmd` (no copies). Returns the number of
/// separators found: 0 means no split, so the caller keeps `cmd` verbatim.
fn splitParallel(allocator: std.mem.Allocator, cmd: []const u8, out: *std.ArrayList([]const u8)) !usize {
    var start: usize = 0;
    var n_sep: usize = 0;
    for (cmd, 0..) |c, i| if (c == '+' and parallelSepAt(cmd, i)) {
        n_sep += 1;
        const frag = std.mem.trim(u8, cmd[start..i], " \t");
        if (frag.len > 0) try out.append(allocator, frag);
        start = i + 1;
    };
    const tail = std.mem.trim(u8, cmd[start..], " \t");
    if (tail.len > 0) try out.append(allocator, tail);
    return n_sep;
}

/// Resolves one config-list element (or a lone string value) into its Action.
/// A `+`-linked batch becomes a `.parallel` group; without separators the
/// result is a single action (byte-for-byte the previous element behavior).
fn resolveElement(
    allocator: std.mem.Allocator,
    cmd: []const u8,
    ws_idx: u16,
    kill: ?[]const u8,
) !types.Action {
    var frags: std.ArrayList([]const u8) = .empty;
    defer frags.deinit(allocator);
    const n_sep = try splitParallel(allocator, cmd, &frags);
    if (n_sep == 0) return resolveAndParseAction(allocator, cmd, ws_idx, kill);
    if (frags.items.len <= 1)
        return resolveAndParseAction(allocator, if (frags.items.len == 1) frags.items[0] else cmd, ws_idx, kill);

    var group: std.ArrayList(types.Action) = .empty;
    errdefer {
        for (group.items) |*a| a.deinit(allocator);
        group.deinit(allocator);
    }
    for (frags.items) |frag| try group.append(allocator, try resolveAndParseAction(allocator, frag, ws_idx, kill));
    return .{ .parallel = try group.toOwnedSlice(allocator) };
}

/// Resolves the `Mod+` placeholder in a keybind key: when `mod_placeholder` is
/// set and the key starts with `mod+` (case-insensitive), substitutes the real
/// modifier. Otherwise returns the key unchanged (no allocation).
fn resolveModPlaceholder(
    allocator: std.mem.Allocator,
    key: []const u8,
    mod_placeholder: ?[]const u8,
) ![]const u8 {
    if (mod_placeholder) |mod|
        if (std.ascii.startsWithIgnoreCase(key, "mod+"))
            return try std.fmt.allocPrint(allocator, "{s}+{s}", .{ mod, key["mod+".len..] });
    return key;
}

pub fn parseKeybindings(allocator: std.mem.Allocator, doc: *parser.Document, cfg: *types.Config) !void {
    const section = doc.getSection(types.section_binds) orelse doc.getSection(types.section_binds_alt) orelse return;
    var mod_placeholder: ?[]const u8 = null;
    var kill_placeholder: ?[]const u8 = null;
    var iter = section.orderedIterator();
    while (iter.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key, "Mod")) {
            mod_placeholder = entry.value.asScalar([]const u8);
            continue;
        }
        if (std.ascii.eqlIgnoreCase(entry.key, "kill")) {
            kill_placeholder = entry.value.asScalar([]const u8);
            continue;
        }
        const glob_entries = try expandGlobKeys(allocator, entry.key);
        defer {
            for (glob_entries) |ge| if (ge.owned) allocator.free(ge.key);
            allocator.free(glob_entries);
        }
        for (glob_entries) |ge| {
            const keybind_str: []const u8 = try resolveModPlaceholder(allocator, ge.key, mod_placeholder);
            defer if (keybind_str.ptr != ge.key.ptr) allocator.free(keybind_str);
            var action = try actionFromValue(allocator, entry.value, ge.ws_idx, kill_placeholder) orelse continue;
            const bind = parseBindString(keybind_str) catch |err| {
                log.warn("Failed to parse keybind '{s}': {}", .{ keybind_str, err });
                // The action just built owns heap strings; it isn't stored
                // anywhere on this path, so free it before skipping the bind.
                action.deinit(allocator);
                continue;
            };
            switch (bind) {
                .mouse => |mb| try cfg.mouse_bindings.append(allocator, .{ .modifiers = mb.modifiers, .button = mb.button, .action = action }),
                .keyboard => |kb| try cfg.keybindings.append(allocator, .{ .modifiers = kb.modifiers, .keysym = kb.keysym, .action = action }),
            }
        }
    }
}

const BindResult = union(enum) {
    keyboard: struct { modifiers: u16, keysym: u32 },
    mouse: struct { modifiers: u16, button: u8 },
};

/// Parses a `Mods+Key` or `Mods+ButtonName` string into a typed BindResult.
/// Returns an error when any token is unrecognised.
fn parseBindString(str: []const u8) !BindResult {
    var modifiers: u16 = 0;
    var keysym: ?u32 = null;
    var button: ?u8 = null;
    var parts = std.mem.splitScalar(u8, str, '+');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        // Normalise to lowercase (modifiers are case-insensitive) via a bounded
        // helper; overlong tokens → null.
        var lowered_buf: [max_modifier_key_bytes]u8 = undefined;
        const lowered = types.lowerSlice(max_modifier_key_bytes, &lowered_buf, trimmed);
        const mod: ?u16 = if (lowered) |l| mod_map.get(l) else null;
        if (mod) |m| {
            modifiers |= m;
        } else if (mouse_button_map.get(lowered orelse "")) |btn| {
            if (button != null) return error.MultipleButtons;
            button = btn;
        } else {
            if (button != null) return error.AmbiguousBinding;
            if (keysym != null) return error.MultipleKeys;
            keysym = try keyNameToKeysym(trimmed);
        }
    }
    if (button) |b| {
        if (keysym != null) return error.AmbiguousBinding;
        return .{ .mouse = .{ .modifiers = modifiers, .button = b } };
    }
    return .{ .keyboard = .{ .modifiers = modifiers, .keysym = keysym orelse return error.NoKeysym } };
}

fn keyNameToKeysym(name: []const u8) !u32 {
    if (name.len >= max_key_name_bytes) return error.KeyNameTooLong;
    var buf: [max_key_name_bytes]u8 = undefined;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const keysym = keysyms.keysymFromName(&buf);
    return if (keysym == keysyms.XKB_KEY_NoSymbol) error.UnknownKeyName else keysym;
}
