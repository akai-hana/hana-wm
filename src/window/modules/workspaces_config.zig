//! The workspaces config fragment: `Config` (the [workspaces] subtree), its
//! knob table, and the workspace-rules parsers (the `[workspace.rules]` /
//! `[rules]` families the knob engine does not cover). Deleting this file
//! (with the rest of the optional workspaces module) removes the
//! `workspaces` field, every [workspaces] knob, and the rule parsers.
//!
//! `types.Rule` stays in the shared vocab: the always-compiled admission
//! layer's signatures take `[]const types.Rule` even when this fragment is
//! absent; only the LIST owner lives here.

const std = @import("std");
const log = std.log.scoped(.workspaces_config);
const model = @import("model");
const parser = @import("parser");
const types = @import("types");
const knob = @import("knob");

pub const Config = struct {
    count: u8 = types.default_workspace_count,
    rules: std.ArrayList(types.Rule) = .empty,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.rules.items) |rule| allocator.free(rule.class_name);
        self.rules.deinit(allocator);
    }
};

pub const knobs = [_]knob.Knob{
    // [bar.modules.workspaces] | [workspaces]: first-present-wins. The bar's
    // icon-padding self-seed reads the same document positions directly, so
    // the bar fragment needs no dependency on this one.
    knob.knob(
        &.{ knob.place(types.section_bar_modules_workspaces, "count"), knob.place(types.section_workspaces, "count") },
        "count",
        .{ .int = .{ .T = u8, .min = 1, .max = model.max_workspaces } },
    ),
};

comptime {
    knob.validateTable(Config, &knobs, &.{});
}

/// The section names the workspaces subsystem owns: the composed facade
/// unions every fragment's list into the mis-case lint's inventory.
/// `[bar.modules.workspaces]` is consumed by this fragment's count knob but
/// lives in the bar's section namespace, so bar_config lists it (a name
/// appears in exactly one fragment).
pub const sections = &[_][]const u8{
    types.section_workspaces,
    types.section_workspace_rules,
    types.section_rules,
};

/// Mis-case families: both rule-table families are open sets (one section
/// per workspace / per rule name), so case-variants get the family warn.
pub const section_prefixes = &[_][]const u8{
    types.section_prefix_workspace_rules,
    types.section_prefix_rules,
};

/// Inert families: the numbered rule tables are read only when their parent
/// section is present; a present family with the parent missing leaves those
/// rules inert, which the load warns about.
pub const inert_families = &[_]types.InertFamily{
    .{ .parent = types.section_rules, .child_prefix = types.section_prefix_rules },
    .{ .parent = types.section_workspace_rules, .child_prefix = types.section_prefix_workspace_rules },
};

/// Both rule-table sections accumulate duplicate declarations by design
/// (one key per rule; repeated names read as arrays), so scalar reads of an
/// accumulated rule take the last declaration without a "later wins" warn.
pub const accumulate_exempt = &[_]types.SectionKey{
    .{ .section = types.section_workspace_rules },
    .{ .section = types.section_rules },
};

/// The section HEADS whose presence in the embedded fallback TOML is gated
/// on this fragment's owner module: `workspace` heads the `[workspace.rules*]`
/// family, `rules` the numbered tables.
pub const fallback_sections = &[_][]const u8{ "workspaces", "workspace", "rules" };

/// The fragment parse entry: apply the scalar knobs, then parse the
/// workspace-rules families (which bound-check against the freshly parsed
/// `count`).
pub fn parse(allocator: std.mem.Allocator, doc: *parser.Document) !Config {
    var cfg: Config = .{};
    errdefer cfg.deinit(allocator);
    try knob.applyAll(Config, doc, allocator, &cfg, &knobs);
    try parseRules(allocator, doc, &cfg);
    return cfg;
}

/// No domain invariants beyond the count knob's bounds; present so the
/// composed facade can call `validate` uniformly on every fragment.
pub fn validate(_: *const Config) !void {}

/// Validates a 1-based workspace number, warn-and-skip when outside the
/// 1..`max` window.
fn checkWorkspaceBound(ws_1based: usize, context: []const u8, max: usize) bool {
    if (!types.workspaceInRange(ws_1based, max)) {
        log.warn(
            "{s}: workspace {} out of 1..{} range, skipping",
            .{ context, ws_1based, max },
        );
        return false;
    }
    return true;
}

/// Appends one class rule. A workspace rule binds `class_name` to the
/// 1-based workspace `ws_1based`; a null `ws_1based` makes it a "float" class
/// rule instead (windows are admitted floating on the current workspace,
/// with `workspace` left 0, unused).
fn addRule(
    allocator: std.mem.Allocator,
    cfg: *Config,
    class_name: []const u8,
    ws_1based: ?usize,
) !void {
    try cfg.rules.append(allocator, .{
        .class_name = try allocator.dupe(u8, class_name),
        .workspace = if (ws_1based) |w| @intCast(w - 1) else 0,
        .float = (ws_1based == null),
    });
}

/// The `[workspace.rules]` and `[rules]` families: class-name-to-workspace
/// bindings in both directions, plus the numbered `[workspace.rules.<n>]` /
/// `[rules.<n>]` sub-sections. Gated on the parent section existing, and
/// every owned class name is duped off the parsed document so it outlives
/// the load-scoped arena.
pub fn parseRules(allocator: std.mem.Allocator, doc: *parser.Document, cfg: *Config) !void {
    // [workspace.rules]: key is either a class name (value = a workspace
    // number) or a workspace number (value = class array).
    if (doc.getSection(types.section_workspace_rules)) |s| try parseWorkspaceRuleSection(allocator, cfg, s);
    // [rules]: simple class -> workspace mapping (key = class, value = a
    // workspace number).
    if (doc.getSection(types.section_rules)) |s| {
        var iter = s.orderedIterator();
        while (iter.next()) |entry| {
            try tryAddClassRule(allocator, cfg, entry.key, entry.value);
        }
    }
    try parseNumberedRuleSections(allocator, doc, cfg);
}

/// Processes numbered rule sub-sections (e.g. [workspace.rules.1], [rules.3]).
/// Each section's keys are class names; the name suffix is the workspace
/// number. Shared by both rule-table prefixes.
fn parseNumberedRuleSections(
    allocator: std.mem.Allocator,
    doc: *parser.Document,
    cfg: *Config,
) !void {
    var section_iter = doc.sections.iterator();
    while (section_iter.next()) |entry| {
        const name = entry.key_ptr.*;
        const suffix_len = if (std.mem.startsWith(u8, name, types.section_prefix_workspace_rules)) types.section_prefix_workspace_rules.len else if (std.mem.startsWith(u8, name, types.section_prefix_rules)) types.section_prefix_rules.len else continue;
        const ws_num = std.fmt.parseInt(usize, name[suffix_len..], 10) catch {
            log.warn("Section [{s}]: workspace suffix is not a number, skipping", .{name});
            continue;
        };
        if (!checkWorkspaceBound(ws_num, name, cfg.count)) continue;
        var iter = entry.value_ptr.orderedIterator();
        while (iter.next()) |class_entry| {
            try addRule(allocator, cfg, class_entry.key, ws_num);
        }
    }
}

/// Parses `value` as a workspace int or the "float" marker and, if valid,
/// adds a rule mapping `class_name` accordingly. Shared by the class-keyed
/// direction of [workspace.rules] and by [rules].
fn tryAddClassRule(allocator: std.mem.Allocator, cfg: *Config, class_name: []const u8, value: parser.Value) !void {
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
    else if (checkWorkspaceBound(@intCast(ws_num), class_name, cfg.count))
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
/// (integer value -> workspace) or a workspace number (array value ->
/// classes). Distinguish by the LEADING NUMERIC RUN, not by an all-key
/// parseInt: a numeric-prefixed class like "12x" is parsed as a class rule
/// (warned), never silently coerced by a catch; only all-digit keys are
/// workspace numbers.
fn parseWorkspaceRuleSection(
    allocator: std.mem.Allocator,
    cfg: *Config,
    rules_section: *parser.Section,
) !void {
    var iter = rules_section.orderedIterator();
    while (iter.next()) |entry| {
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
        if (!checkWorkspaceBound(ws_num, entry.key, cfg.count)) continue;
        if (entry.value.asArray()) |arr|
            for (arr) |item|
                if (item.asScalar([]const u8)) |class_name| try addRule(allocator, cfg, class_name, ws_num);
    }
}
