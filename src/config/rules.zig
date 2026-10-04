//! Workspace-rules parsing: the `[workspace.rules]` and `[rules]`
//! families the comptime schema walk (schema.applyAll) does not
//! cover -- class-name-to-workspace bindings in both directions,
//! plus the numbered `[workspace.rules.<n>]` / `[rules.<n>]`
//! sub-sections. Gated on the parent section existing, exactly as
//! the scalar knobs are, and every owned class name is duped off
//! the parsed document so it outlives the load-scoped arena.

const std = @import("std");
const constants = @import("constants");
const log = @import("log");
const parser = @import("parser");
const types = @import("types");

/// Validates a 1-based workspace number, warn-and-skip when outside 1..255 or
/// exceeding `max` (the workspace count / constants.max_workspaces ceiling).
fn checkWorkspaceBound(ws_1based: usize, context: []const u8, max: usize) bool {
    if (ws_1based < 1 or ws_1based > constants.max_workspace_number_1based) {
        log.warn("{s}: workspace {} out of range, skipping", .{ context, ws_1based });
        return false;
    }
    if (ws_1based > max) {
        log.warn(
            "{s}: workspace {} exceeds the {}-workspace limit, skipping",
            .{ context, ws_1based, max },
        );
        return false;
    }
    return true;
}

/// Appends one class rule. A workspace rule binds `class_name` to the
/// 1-based workspace `ws_1based`; a null `ws_1based` makes it a "float" class
/// rule instead (windows are admitted floating on the current workspace, with
/// `workspace` left 0, unused).
fn addRule(
    allocator: std.mem.Allocator,
    cfg: *types.Config,
    class_name: []const u8,
    ws_1based: ?usize,
) !void {
    try cfg.workspaces.rules.append(allocator, .{
        .class_name = try allocator.dupe(u8, class_name),
        .workspace = if (ws_1based) |w| @intCast(w - 1) else 0,
        .float = (ws_1based == null),
    });
}

pub fn parseRules(allocator: std.mem.Allocator, doc: *parser.Document, cfg: *types.Config) !void {
    // [workspace.rules]: key is either a class name (value = ws int) or a
    // workspace number (value = class array). Both directions call addRule.
    if (doc.getSection(types.section_workspace_rules)) |s| try parseWorkspaceRuleSection(allocator, cfg, s);
    // [rules]: simple class -> workspace mapping (key = class, value = ws int).
    if (doc.getSection(types.section_rules)) |s| {
        var iter = s.orderedIterator();
        while (iter.next()) |entry| {
            s.markConsumed(entry.key);
            try tryAddClassRule(allocator, cfg, entry.key, entry.value);
        }
    }
    try parseNumberedRuleSections(allocator, doc, cfg);
}

/// Processes numbered rule sub-sections (e.g. [workspace.rules.1], [rules.3]).
/// Each section's keys are class names; the section name suffix is the workspace
/// number. Shared by both "workspace.rules.*" and "rules.*" prefixes.
fn parseNumberedRuleSections(
    allocator: std.mem.Allocator,
    doc: *parser.Document,
    cfg: *types.Config,
) !void {
    var section_iter = doc.sections.iterator();
    while (section_iter.next()) |entry| {
        const name = entry.key_ptr.*;
        const suffix_len = if (std.mem.startsWith(u8, name, types.section_prefix_workspace_rules)) types.section_prefix_workspace_rules.len else if (std.mem.startsWith(u8, name, types.section_prefix_rules)) types.section_prefix_rules.len else continue;
        const ws_num = std.fmt.parseInt(usize, name[suffix_len..], 10) catch {
            log.warn("Section [{s}]: workspace suffix is not a number, skipping", .{name});
            continue;
        };
        if (!checkWorkspaceBound(ws_num, name, cfg.workspaces.count)) continue;
        var iter = entry.value_ptr.orderedIterator();
        while (iter.next()) |class_entry| {
            entry.value_ptr.markConsumed(class_entry.key);
            try addRule(allocator, cfg, class_entry.key, ws_num);
        }
    }
}

/// Parses `value` as a workspace int or the "float" marker and, if valid, adds
/// a rule mapping `class_name` accordingly. Shared by the class-keyed
/// direction of [workspace.rules] and by [rules], which are always class-keyed.
fn tryAddClassRule(allocator: std.mem.Allocator, cfg: *types.Config, class_name: []const u8, value: parser.Value) !void {
    if (value.asScalar([]const u8)) |s| {
        if (std.mem.eql(u8, s, "float")) {
            try addRule(allocator, cfg, class_name, null);
            return;
        }
        log.warn("Rule for '{s}' has string value '{s}', only integer or \"float\" supported, skipping", .{ class_name, s });
        return;
    }
    const ws_num = value.asScalar(i64) orelse {
        log.warn("Rule for '{s}' has non-integer value, skipping", .{class_name});
        return;
    };
    if (ws_num < 1)
        log.warn("Rule workspace {d} for '{s}' below minimum 1, skipping", .{ ws_num, class_name })
    else if (checkWorkspaceBound(@intCast(ws_num), class_name, cfg.workspaces.count))
        try addRule(allocator, cfg, class_name, @intCast(ws_num));
}

/// Length of the leading run of ASCII digits in `s` (0 when it starts with
/// any other character).
fn countLeadingDigits(s: []const u8) usize {
    var n: usize = 0;
    while (n < s.len and std.ascii.isDigit(s[n])) n += 1;
    return n;
}

/// Handle the [workspace.rules] section where the key may be a class name
/// (integer value -> workspace) or a workspace number (array value -> classes).
/// Distinguish by the LEADING NUMERIC RUN, not by an all-key parseInt: a
/// numeric-prefixed class like "12x" is parsed as a probability-1 class rule
/// (warned), never silently coerced by a catch; only all-digit keys are
/// workspace numbers.
fn parseWorkspaceRuleSection(
    allocator: std.mem.Allocator,
    cfg: *types.Config,
    rules_section: *parser.Section,
) !void {
    var iter = rules_section.orderedIterator();
    while (iter.next()) |entry| {
        rules_section.markConsumed(entry.key);
        const digit_run = countLeadingDigits(entry.key);
        if (digit_run == 0) {
            try tryAddClassRule(allocator, cfg, entry.key, entry.value);
            continue;
        }
        if (digit_run != entry.key.len) {
            log.warn("[workspace.rules]: key '{s}' starts with a digit but isn't a workspace number, treating it as a class name", .{entry.key});
            try tryAddClassRule(allocator, cfg, entry.key, entry.value);
            continue;
        }
        // All-digits: an oversized value is a genuine parse error (never a
        // plausible workspace number), so warn-and-skip rather than coerce
        // into a class rule.
        const ws_num = std.fmt.parseInt(usize, entry.key, 10) catch {
            log.warn("[workspace.rules]: workspace number '{s}' is too large, skipping", .{entry.key});
            continue;
        };
        if (!checkWorkspaceBound(ws_num, entry.key, cfg.workspaces.count)) continue;
        if (entry.value.asArray()) |arr|
            for (arr) |item|
                if (item.asScalar([]const u8)) |class_name| try addRule(allocator, cfg, class_name, ws_num);
    }
}
