//! Configuration interpreter

const std = @import("std");
const defs = @import("defs");
const debug = @import("debug");
const parser = @import("parser");
const xkb = @import("xkbcommon");

// CONSOLIDATED: Use parseColor from parser module (removed duplicate)
const parseColor = parser.parseColor;

fn getColor(section: *const parser.Section, key: []const u8, default: u32) u32 {
    const value = section.get(key) orelse return default;
    if (value.asColor()) |color| {
        return if (color <= 0xFFFFFF) color else default;
    }
    if (value.asString()) |str| {
        const color = parseColor(str) catch {
            debug.warn("Invalid color for {s}: '{s}'", .{ key, str });
            return default;
        };
        return color;
    }
    if (value.asInt()) |int_val| {
        const color: u32 = @intCast(int_val);
        return if (color <= 0xFFFFFF) color else default;
    }
    return default;
}

// Simplified getter with inline validation and logging
// When values are out of bounds, returns the default value (NOT clamped)
fn get(
    comptime T: type,
    section: *const parser.Section,
    key: []const u8,
    default: T,
    comptime min: ?T,
    comptime max: ?T,
) T {
    const value = switch (T) {
        bool => section.getBool(key) orelse return default,
        []const u8 => section.getString(key) orelse return default,
        f32 => blk: {
            if (section.getInt(key)) |i| {
                break :blk @as(f32, @floatFromInt(i)) / 100.0;
            }
            return default;
        },
        u8, u16, u32, usize => blk: {
            const i = section.getInt(key) orelse return default;
            break :blk @as(T, @intCast(i));
        },
        else => @compileError("Unsupported type"),
    };
    // Validate bounds and warn if out of range - returns default, NOT clamped value
    if (comptime min) |m| {
        if (value < m) {
            debug.warn("Value for '{s}' ({any}) below minimum ({any}), using default", .{key, value, m});
            return default;
        }
    }
    if (comptime max) |m| {
        if (value > m) {
            debug.warn("Value for '{s}' ({any}) above maximum ({any}), using default", .{key, value, m});
            return default;
        }
    }
    return value;
}

fn getScalable(section: *const parser.Section, key: []const u8, default: parser.ScalableValue) parser.ScalableValue {
    return section.getScalable(key) orelse default;
}

// CONSOLIDATED: Helper for workspace range validation
fn validateWorkspace(ws_num: usize, max: usize, context: []const u8) bool {
    if (ws_num < 1 or ws_num > max) {
        debug.warn("Rule workspace {} for '{s}' exceeds count {}, skipping", .{ ws_num, context, max });
        return false;
    }
    return true;
}

// CONSOLIDATED: Helper for creating and adding rules
fn addRule(allocator: std.mem.Allocator, cfg: *defs.Config, class_name: []const u8, ws_num: usize) !void {
    const rule = defs.Rule{
        .class_name = try allocator.dupe(u8, class_name),
        .workspace = @intCast(ws_num - 1),
    };
    try cfg.workspaces.rules.append(allocator, rule);
}

// CONSOLIDATED: Helper for initializing default bar layout
fn initDefaultBarLayout(allocator: std.mem.Allocator, cfg: *defs.Config) !void {
    const layout_defaults = [_]struct{pos: defs.BarPosition, seg: defs.BarSegment}{
        .{.pos = .left, .seg = .workspaces},
        .{.pos = .center, .seg = .title},
        .{.pos = .right, .seg = .clock},
    };
    for (layout_defaults) |ld| {
        var bar_layout = defs.BarLayout{ .position = ld.pos, .segments = std.ArrayList(defs.BarSegment){} };
        try bar_layout.segments.append(allocator, ld.seg);
        try cfg.bar.layout.append(allocator, bar_layout);
    }
}

pub fn loadConfigDefault(allocator: std.mem.Allocator) !defs.Config {
    const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else ".";
    const config_home = if (std.c.getenv("XDG_CONFIG_HOME")) |ch|
        std.mem.span(ch)
    else
        try std.fmt.allocPrint(allocator, "{s}/.config", .{home});
    defer if (std.c.getenv("XDG_CONFIG_HOME") == null) allocator.free(config_home);

    const xdg_path = try std.fs.path.join(allocator, &.{ config_home, "hana", "config.toml" });
    defer allocator.free(xdg_path);

    if (loadConfig(allocator, xdg_path)) |cfg| {
        return cfg;
    } else |_| {
        const cwd = try std.process.getCwdAlloc(allocator);
        defer allocator.free(cwd);
        const local = try std.fs.path.join(allocator, &.{ cwd, "config.toml" });
        defer allocator.free(local);
        if (loadConfig(allocator, local)) |cfg| {
            return cfg;
        } else |_| {
            debug.info("No config.toml found, using fallback with auto-detection", .{});
            return try loadFallbackConfig(allocator);
        }
    }
}

// CONSOLIDATED: Extracted common config parsing logic
fn parseConfigSections(allocator: std.mem.Allocator, doc: *const parser.Document, cfg: *defs.Config) !void {
    parseWorkspaces(doc, cfg);
    try parseKeybindings(allocator, doc, cfg);
    try parseTiling(allocator, doc, cfg);
    try parseBar(allocator, doc, cfg);
    try parseRules(allocator, doc, cfg);
}

pub fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !defs.Config {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const fd = std.posix.open(path_z, .{ .ACCMODE = .RDONLY }, 0) catch |err| {
        if (err == error.FileNotFound) {
            debug.info("Not found: {s}", .{path});
            return err;
        }
        return err;
    };
    defer std.posix.close(fd);

    var content: std.ArrayList(u8) = .{};
    defer content.deinit(allocator);
    try content.ensureTotalCapacity(allocator, 4096);

    var buf: [4096]u8 = undefined;
    while (true) {
        const bytes_read = try std.posix.read(fd, &buf);
        if (bytes_read == 0) break;
        try content.appendSlice(allocator, buf[0..bytes_read]);
        if (content.items.len > 1024 * 1024) return error.FileTooLarge;
    }

    if (content.items.len == 0) {
        debug.info("Empty config file: {s}, using fallback", .{path});
        return try loadFallbackConfig(allocator);
    }

    var doc = try parser.parse(allocator, content.items);
    defer doc.deinit();

    var cfg = getDefaultConfig(allocator);
    try parseConfigSections(allocator, &doc, &cfg);
    debug.info("Loaded: {s}", .{path});
    return cfg;
}

fn loadFallbackConfig(allocator: std.mem.Allocator) !defs.Config {
    const fallback = @import("fallback");
    const fallback_toml = fallback.getFallbackToml();
    
    var doc = try parser.parse(allocator, fallback_toml);
    defer doc.deinit();

    var cfg = getDefaultConfig(allocator);
    try parseConfigSections(allocator, &doc, &cfg);

    const terminal = try fallback.detectTerminal(allocator);
    for (cfg.keybindings.items) |*kb| {
        if (kb.action == .exec) {
            if (std.mem.eql(u8, kb.action.exec, "auto_terminal")) {
                allocator.free(kb.action.exec);
                kb.action.exec = try allocator.dupe(u8, terminal);
            }
        }
    }

    if (std.mem.eql(u8, cfg.bar.font, "auto")) {
        const detected_font = try fallback.detectFont(allocator);
        // Use the raw value from ScalableValue (will be scaled later during bar init)
        const font_size_val: u16 = @intFromFloat(cfg.bar.font_size.value);
        const font_with_size = try std.fmt.allocPrint(allocator, "{s}:size={}", .{detected_font, font_size_val});
        cfg.bar.font = font_with_size;
    }

    debug.info("Loaded fallback configuration with auto-detection", .{});
    return cfg;
}

fn getDefaultConfig(allocator: std.mem.Allocator) defs.Config {
    var cfg = defs.Config.init(allocator);
    
    // Add default tiling layout
    const default_layout = allocator.dupe(u8, "master_left") catch "master_left";
    cfg.tiling.layouts.append(allocator, default_layout) catch |e| debug.warnOnErr(e, "default layout append");
    cfg.tiling.layout = if (cfg.tiling.layouts.items.len > 0) cfg.tiling.layouts.items[0] else "master_left";
    
    for (0..9) |i| {
        const icon = std.fmt.allocPrint(allocator, "{}", .{i + 1}) catch continue;
        cfg.bar.workspace_icons.append(allocator, icon) catch |e| debug.warnOnErr(e, "workspace icon append");
    }
    
    initDefaultBarLayout(allocator, &cfg) catch |e| debug.warnOnErr(e, "default bar layout init");
    return cfg;
}

const MOD_MAP = std.StaticStringMap(u16).initComptime(.{
    .{ "Super", defs.MOD_SUPER },
    .{ "Mod4", defs.MOD_SUPER },
    .{ "Alt", defs.MOD_ALT },
    .{ "Mod1", defs.MOD_ALT },
    .{ "Control", defs.MOD_CONTROL },
    .{ "Ctrl", defs.MOD_CONTROL },
    .{ "Shift", defs.MOD_SHIFT },
});

const ACTION_MAP = std.StaticStringMap(defs.Action).initComptime(.{
    .{ "close", .close_window },
    .{ "close_window", .close_window },
    .{ "kill", .close_window },
    .{ "reload", .reload_config },
    .{ "reload_config", .reload_config },
    .{ "toggle_layout", .toggle_layout },
    .{ "toggle_layout_reverse", .toggle_layout_reverse },
    .{ "toggle_bar_visibility", .toggle_bar_visibility },
    .{ "toggle_bar_position", .toggle_bar_position },
    .{ "increase_master", .increase_master },
    .{ "decrease_master", .decrease_master },
    .{ "increase_master_count", .increase_master_count },
    .{ "decrease_master_count", .decrease_master_count },
    .{ "toggle_tiling", .toggle_tiling },
    .{ "toggle_fullscreen", .toggle_fullscreen },
    .{ "fullscreen", .toggle_fullscreen },
    .{ "swap_master", .swap_master },
    .{ "dump_state", .dump_state },
    .{ "emergency_recover", .emergency_recover },
});

fn parseKeybindings(allocator: std.mem.Allocator, doc: *const parser.Document, cfg: *defs.Config) !void {
    // Support both [binds] (new) and [Keybindings] (legacy) section names
    const section = doc.getSection("binds") orelse doc.getSection("Keybindings") orelse return;
    const mod_placeholder = section.getString("Mod");
    const kill_placeholder = section.getString("kill") orelse return;

    var iter = section.pairs.iterator();
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "Mod")) continue;
        if (std.mem.eql(u8, entry.key_ptr.*, "kill")) continue;
        
        const command = entry.value_ptr.*.asString() orelse continue;

        const keybind_str = if (mod_placeholder) |mod|
            try substituteModVariable(allocator, entry.key_ptr.*, mod)
        else
            entry.key_ptr.*;
        defer if (mod_placeholder != null) allocator.free(keybind_str);

        const parts = parseKeybindString(keybind_str) catch |err| {
            debug.warn("Failed to parse keybind '{s}': {}", .{ keybind_str, err });
            continue;
        };

        // Substitute {kill} placeholder in commands
        const final_command = if (std.mem.indexOf(u8, command, "{kill}")) |_|
            try std.mem.replaceOwned(u8, allocator, command, "{kill}", kill_placeholder)
        else
            command;
        defer if (final_command.ptr != command.ptr) allocator.free(final_command);

        try cfg.keybindings.append(allocator, .{
            .modifiers = parts.modifiers,
            .keysym = parts.keysym,
            .action = try parseAction(allocator, final_command),
        });
    }
}

fn substituteModVariable(allocator: std.mem.Allocator, keybind: []const u8, mod: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, keybind, "Mod+")) {
        return try std.fmt.allocPrint(allocator, "{s}+{s}", .{ mod, keybind[4..] });
    }
    return try allocator.dupe(u8, keybind);
}

fn parseKeybindString(str: []const u8) !struct { modifiers: u16, keysym: u32 } {
    var modifiers: u16 = 0;
    var keysym: ?u32 = null;

    var parts = std.mem.splitScalar(u8, str, '+');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");

        if (MOD_MAP.get(trimmed)) |mod| {
            modifiers |= mod;
        } else {
            if (keysym != null) return error.MultipleKeys;
            keysym = try keyNameToKeysym(trimmed);
        }
    }
    return .{ .modifiers = modifiers, .keysym = keysym orelse return error.NoKeysym };
}

fn keyNameToKeysym(name: []const u8) !u32 {
    if (name.len >= 64) return error.KeyNameTooLong;
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const keysym = xkb.xkb_keysym_from_name(@ptrCast(&buf), xkb.XKB_KEYSYM_CASE_INSENSITIVE);
    return if (keysym == xkb.XKB_KEY_NoSymbol) error.UnknownKeyName else keysym;
}

// OPTIMIZATION: Generic workspace action parser
fn tryParseWorkspace(command: []const u8, prefix: []const u8) ?u8 {
    if (!std.mem.startsWith(u8, command, prefix)) return null;
    const num = std.fmt.parseInt(usize, command[prefix.len..], 10) catch return null;
    if (num < 1) return null;
    return @intCast(num - 1);
}

fn parseAction(allocator: std.mem.Allocator, cmd: []const u8) !defs.Action {
    if (ACTION_MAP.get(cmd)) |action| return action;

    if (tryParseWorkspace(cmd, "workspace_")) |ws| return .{ .switch_workspace = ws };
    if (tryParseWorkspace(cmd, "move_to_workspace_")) |ws| return .{ .move_to_workspace = ws };
    
    return .{ .exec = try allocator.dupe(u8, cmd) };
}

/// Finalize configuration with screen-dependent values (call after screen is available)
pub fn finalizeConfig(cfg: *defs.Config, screen: *defs.xcb.xcb_screen_t) void {
    const dpi_module = @import("dpi");
    // Compute scaled font size based on ScalableValue
    cfg.bar.scaled_font_size = dpi_module.scaleFontSize(cfg.bar.font_size, screen);
}

pub fn resolveKeybindings(keybindings: anytype, xkb_state: *xkb.XkbState) void {
    // First pass: resolve keycodes
    for (keybindings) |*kb| {
        kb.keycode = xkb_state.keysymToKeycode(kb.keysym);
    }
    // Second pass: detect conflicts
    // Map of (modifiers + keycode) -> binding index for conflict detection
    var seen = std.AutoHashMap(u64, usize).init(std.heap.c_allocator);
    defer seen.deinit();
    
    for (keybindings, 0..) |*kb, i| {
        const keycode = kb.keycode orelse continue;
        // Create unique key from modifiers and keycode
        const key: u64 = (@as(u64, kb.modifiers) << 32) | keycode;
        
        if (seen.get(key)) |first_index| {
            debug.warn("Keybinding conflict detected!", .{});
            debug.warn("  Binding #{}: mods=0x{x:0>4} key={} (first)", .{
                first_index + 1, keybindings[first_index].modifiers, keycode
            });
            debug.warn("  Binding #{}: mods=0x{x:0>4} key={} (duplicate)", .{
                i + 1, kb.modifiers, keycode
            });
            debug.warn("  The second binding will override the first!", .{});
        } else {
            seen.put(key, i) catch {};
        }
    }
}

fn parseTiling(allocator: std.mem.Allocator, doc: *const parser.Document, cfg: *defs.Config) !void {
    const section = doc.getSection("tiling") orelse return;
    cfg.tiling.enabled = get(bool, section, "enabled", true, null, null);

    // Parse layouts array (new structure)
    if (section.get("layouts")) |layouts_value| {
        if (layouts_value.asArray()) |layouts_arr| {
            for (cfg.tiling.layouts.items) |layout| allocator.free(layout);
            cfg.tiling.layouts.clearRetainingCapacity();
            
            for (layouts_arr) |layout_item| {
                if (layout_item.asString()) |layout_str| {
                    const layout_copy = try allocator.dupe(u8, layout_str);
                    try cfg.tiling.layouts.append(allocator, layout_copy);
                }
            }
            
            // Set current layout to first in array if available
            if (cfg.tiling.layouts.items.len > 0) {
                cfg.tiling.layout = cfg.tiling.layouts.items[0];
            }
        }
    } else {
        // Fallback to old "layout" field if layouts array not present
        const layout_str = get([]const u8, section, "layout", "master_left", null, null);
        cfg.allocated_layout = try allocator.dupe(u8, layout_str);
        cfg.tiling.layout = cfg.allocated_layout.?;
        
        // Also add to layouts array for consistency
        const layout_copy = try allocator.dupe(u8, layout_str);
        try cfg.tiling.layouts.append(allocator, layout_copy);
    }

    // Try parsing from new [tiling.aesthetics] section first
    const aesthetics_section = doc.getSection("tiling.aesthetics");
    const aesthetic_src = aesthetics_section orelse section;
    
    cfg.tiling.gaps = getScalable(aesthetic_src, "gaps", parser.ScalableValue.absolute(10.0));
    cfg.tiling.border_width = getScalable(aesthetic_src, "border_width", parser.ScalableValue.absolute(2.0));
    cfg.tiling.border_focused = getColor(aesthetic_src, "border_focused", 0x5294E2);
    cfg.tiling.border_unfocused = getColor(aesthetic_src, "border_unfocused", 0x383C4A);

    // Try parsing from new [tiling.layouts.master-stack] section
    const master_stack_section = doc.getSection("tiling.layouts.master-stack");
    const master_src = master_stack_section orelse section;
    
    // Use new names if in master-stack section, old names otherwise
    const count_key = if (master_stack_section != null) "count" else "master_count";
    const side_key = if (master_stack_section != null) "side" else "master_side";
    const width_key = if (master_stack_section != null) "width" else "master_width";
    
    cfg.tiling.master_count = get(u8, master_src, count_key, 1, 1, null);
    
    if (master_src.getString(side_key)) |side_str| {
        cfg.tiling.master_side = defs.MasterSide.fromStringWithAlias(side_str) orelse .left;
    }
    
    cfg.tiling.master_width = getScalable(master_src, width_key, parser.ScalableValue.percentage(50.0));
}

// OPTIMIZATION: Table-driven bar color parsing
const BarColorField = struct {
    name: []const u8,
    field_name: []const u8,
    default: u32,
};

const BAR_COLOR_FIELDS = [_]BarColorField{
    .{ .name = "bg", .field_name = "bg", .default = 0x222222 },
    .{ .name = "fg", .field_name = "fg", .default = 0xBBBBBB },
    .{ .name = "selected_bg", .field_name = "selected_bg", .default = 0x005577 },
    .{ .name = "selected_fg", .field_name = "selected_fg", .default = 0xEEEEEE },
    .{ .name = "occupied_fg", .field_name = "occupied_fg", .default = 0xEEEEEE },
    .{ .name = "urgent_bg", .field_name = "urgent_bg", .default = 0xFF0000 },
    .{ .name = "urgent_fg", .field_name = "urgent_fg", .default = 0xFFFFFF },
    .{ .name = "accent_color", .field_name = "accent_color", .default = 0x61AFEF },
};

fn parseBar(allocator: std.mem.Allocator, doc: *const parser.Document, cfg: *defs.Config) !void {
    const section = doc.getSection("bar") orelse return;
    cfg.bar.enabled = get(bool, section, "enabled", true, null, null);
    
    if (section.getString("position")) |pos_str| {
        cfg.bar.vertical_position = defs.BarVerticalPosition.fromString(pos_str) orelse .top;
    }
    if (section.getInt("height")) |h| {
        cfg.bar.height = @intCast(std.math.clamp(h, 16, 100));
    }

    const font_str = get([]const u8, section, "font", "monospace:size=10", null, null);
    cfg.allocated_font = try allocator.dupe(u8, font_str);
    cfg.bar.font = cfg.allocated_font.?;

    if (section.get("fonts")) |value| {
        if (value.asArray()) |arr| {
            for (cfg.bar.fonts.items) |font| allocator.free(font);
            cfg.bar.fonts.clearRetainingCapacity();
            for (arr) |item| {
                if (item.asString()) |font_name| {
                    const font_copy = try allocator.dupe(u8, font_name);
                    try cfg.bar.fonts.append(allocator, font_copy);
                }
            }
            debug.info("Loaded {} fonts for bar", .{cfg.bar.fonts.items.len});
        }
    }

    cfg.bar.font_size = getScalable(section, "font_size", parser.ScalableValue.percentage(10.0));
    cfg.bar.padding = get(u8, section, "padding", 8, 0, 50);
    cfg.bar.spacing = get(u8, section, "spacing", 12, 0, 100);

    // OPTIMIZATION: Table-driven color parsing (saves 11 LOC)
    inline for (BAR_COLOR_FIELDS) |field| {
        @field(cfg.bar, field.field_name) = getColor(section, field.name, field.default);
    }
    
    // Accent-based colors with fallback
    cfg.bar.workspaces_accent = getColor(section, "workspaces_accent", cfg.bar.accent_color);
    cfg.bar.title_accent_color = getColor(section, "title_accent_color", cfg.bar.accent_color);
    cfg.bar.clock_accent = getColor(section, "clock_accent", cfg.bar.accent_color);

    const clock_fmt = get([]const u8, section, "clock_format", "%Y-%m-%d %H:%M:%S", null, null);
    cfg.allocated_clock_format = try allocator.dupe(u8, clock_fmt);
    cfg.bar.clock_format = cfg.allocated_clock_format.?;

    cfg.bar.indicator_size = getScalable(section, "indicator_size", parser.ScalableValue.percentage(100.0));
    cfg.bar.workspace_width = getScalable(section, "workspace_width", parser.ScalableValue.percentage(100.0));
    
    // Parse transparency value - supports multiple formats:
    // - Bare decimals: 0.5, 0.75
    // - Quoted decimals: "0.5", '0.5'
    // - Integers: 50, 75, 100
    // - Quoted integers: "50", '75'
    // - Percentages: 50%, 75%, 100%
    // Special case: 1, "1", '1', or 100% = fully opaque (skip transparency)
    if (section.get("transparency")) |value| {
        var trans: f32 = 1.0;
        
        // Check integers FIRST (before scalable) to properly handle bare numbers like 50
        if (value.asInt()) |i| {
            // Integer value: 0, 1, 50, 100, etc.
            if (i == 0) {
                trans = 0.0;  // Fully transparent
            } else if (i == 1) {
                trans = 1.0;  // Fully opaque - skip transparency
                debug.info("Transparency set to 1 (fully opaque) - transparency disabled", .{});
            } else if (i >= 2 and i <= 100) {
                trans = @as(f32, @floatFromInt(i)) / 100.0;  // Treat as percentage
            } else {
                debug.warn("Invalid transparency value {} (must be 0-100), using default", .{i});
                trans = 1.0;
            }
        } else if (value.asScalable()) |scalable| {
            // Scalable value with explicit percentage marker
            if (scalable.is_percentage) {
                // It's a percentage like 50%
                trans = scalable.value / 100.0;
            } else {
                // Bare decimal like 0.5
                trans = scalable.value;
            }
        } else if (value.asString()) |str| {
            // String value: "0.5", "50", "1", etc.
            const trimmed = std.mem.trim(u8, str, " \t");
            
            // Try parsing as float first (handles "0.5", "0.75", "1.0", etc.)
            if (std.fmt.parseFloat(f32, trimmed)) |float_val| {
                // Check if it's the special case of 1.0 (fully opaque)
                if (float_val == 1.0) {
                    trans = 1.0;
                    debug.info("Transparency set to 1.0 (fully opaque) - transparency disabled", .{});
                } else if (float_val >= 0.0 and float_val < 1.0) {
                    // Decimal value (0.0 - 0.99)
                    trans = float_val;
                } else if (float_val >= 1.0 and float_val <= 100.0) {
                    // Treat as percentage (1-100)
                    trans = float_val / 100.0;
                } else {
                    debug.warn("Invalid transparency value {d} (must be 0.0-1.0 or 0-100), using default", .{float_val});
                    trans = 1.0;
                }
            } else |_| {
                debug.warn("Invalid transparency value '{s}', using default", .{trimmed});
                trans = 1.0;
            }
        }
        
        // Clamp to valid range
        cfg.bar.transparency = std.math.clamp(trans, 0.0, 1.0);
        
        // Log the final value
        if (cfg.bar.transparency == 1.0) {
            debug.info("Bar transparency: disabled (fully opaque)", .{});
        } else {
            debug.info("Bar transparency set to: {d:.2}% (alpha: 0x{x:0>4})", 
                .{cfg.bar.transparency * 100.0, cfg.bar.getAlpha16()});
        }
    }
    
    try parseWorkspaceIcons(allocator, section, cfg);
    try parseBarLayout(allocator, section, doc, cfg);
    
    // Override with bar.colors section if present
    if (doc.getSection("bar.colors")) |colors_section| {
        cfg.bar.workspaces_accent = getColor(colors_section, "workspaces", cfg.bar.workspaces_accent orelse cfg.bar.accent_color);
        cfg.bar.title_accent_color = getColor(colors_section, "title", cfg.bar.title_accent_color orelse cfg.bar.accent_color);
        cfg.bar.clock_accent = getColor(colors_section, "clock", cfg.bar.clock_accent orelse cfg.bar.accent_color);
    }
}

fn parseWorkspaceIcons(allocator: std.mem.Allocator, section: *const parser.Section, cfg: *defs.Config) !void {
    for (cfg.bar.workspace_icons.items) |icon| allocator.free(icon);
    cfg.bar.workspace_icons.clearRetainingCapacity();
    
    if (section.get("icons")) |value| {
        if (value.asArray()) |arr| {
            for (arr) |item| {
                if (item.asString()) |str| {
                    const icon = try allocator.dupe(u8, str);
                    try cfg.bar.workspace_icons.append(allocator, icon);
                } else if (item.asInt()) |num| {
                    const icon = try std.fmt.allocPrint(allocator, "{}", .{num});
                    try cfg.bar.workspace_icons.append(allocator, icon);
                }
            }
        } else if (value.asString()) |str| {
            for (str) |ch| {
                const icon = try std.fmt.allocPrint(allocator, "{c}", .{ch});
                try cfg.bar.workspace_icons.append(allocator, icon);
            }
        }
    }
    
    while (cfg.bar.workspace_icons.items.len < cfg.workspaces.count) : ({}) {
        const icon = try std.fmt.allocPrint(allocator, "{}", .{cfg.bar.workspace_icons.items.len + 1});
        try cfg.bar.workspace_icons.append(allocator, icon);
    }
}

fn parseBarLayout(allocator: std.mem.Allocator, section: *const parser.Section, doc: *const parser.Document, cfg: *defs.Config) !void {
    for (cfg.bar.layout.items) |*item| item.deinit(allocator);
    cfg.bar.layout.clearRetainingCapacity();
    
    if (section.get("layout")) |value| {
        if (value.asArray()) |_| {
            debug.warn("bar.layout array parsing not yet fully supported, use sections like [bar.layout.left]", .{});
        }
    }
    
    const positions = [_]struct { name: []const u8, pos: defs.BarPosition }{
        .{ .name = "bar.layout.left", .pos = .left },
        .{ .name = "bar.layout.center", .pos = .center },
        .{ .name = "bar.layout.right", .pos = .right },
    };
    
    for (positions) |p| {
        if (doc.getSection(p.name)) |layout_section| {
            var bar_layout = defs.BarLayout{
                .position = p.pos,
                .segments = std.ArrayList(defs.BarSegment){},
            };
            if (layout_section.get("segments")) |seg_value| {
                if (seg_value.asArray()) |seg_arr| {
                    for (seg_arr) |seg_item| {
                        if (seg_item.asString()) |seg_str| {
                            if (defs.BarSegment.fromString(seg_str)) |segment| {
                                try bar_layout.segments.append(allocator, segment);
                            }
                        }
                    }
                }
            }
            if (bar_layout.segments.items.len > 0) {
                try cfg.bar.layout.append(allocator, bar_layout);
            } else {
                bar_layout.deinit(allocator);
            }
        }
    }
    
    if (cfg.bar.layout.items.len == 0) {
        try initDefaultBarLayout(allocator, cfg);
    }
}

fn parseWorkspaces(doc: *const parser.Document, cfg: *defs.Config) void {
    // Support both [bar.modules.workspaces] (new) and [workspaces] (legacy)
    const section = doc.getSection("bar.modules.workspaces") orelse doc.getSection("workspaces") orelse return;
    cfg.workspaces.count = get(u8, section, "count", 9, 1, null); // Minimum 1 workspace required
}

fn parseRules(allocator: std.mem.Allocator, doc: *const parser.Document, cfg: *defs.Config) !void {
    // Support alternative array format: [workspace.rules] with numbered arrays
    // e.g., 1 = ["Navigator", "Firefox"]
    if (doc.getSection("workspace.rules")) |rules_section| {
        var iter = rules_section.pairs.iterator();
        while (iter.next()) |entry| {
            const ws_num = std.fmt.parseInt(usize, entry.key_ptr.*, 10) catch {
                // Not a number, try old format
                const ws = entry.value_ptr.*.asInt() orelse continue;
                if (!validateWorkspace(@intCast(ws), cfg.workspaces.count, entry.key_ptr.*)) continue;
                try addRule(allocator, cfg, entry.key_ptr.*, @intCast(ws));
                continue;
            };
            
            // New array format: key is workspace number, value is array of class names
            if (!validateWorkspace(ws_num, cfg.workspaces.count, entry.key_ptr.*)) continue;
            
            if (entry.value_ptr.*.asArray()) |arr| {
                for (arr) |item| {
                    if (item.asString()) |class_name| {
                        try addRule(allocator, cfg, class_name, ws_num);
                    }
                }
            }
        }
    }
    
    // Legacy format support: [rules] section
    if (doc.getSection("rules")) |section| {
        var iter = section.pairs.iterator();
        while (iter.next()) |entry| {
            const ws_num = entry.value_ptr.*.asInt() orelse continue;
            if (!validateWorkspace(@intCast(ws_num), cfg.workspaces.count, entry.key_ptr.*)) continue;
            try addRule(allocator, cfg, entry.key_ptr.*, @intCast(ws_num));
        }
    }

    // Per-workspace sections: [workspace.rules.N]
    var section_iter = doc.sections.iterator();
    while (section_iter.next()) |entry| {
        const name = entry.key_ptr.*;
        const ws_str = if (std.mem.startsWith(u8, name, "workspace.rules."))
            name[16..]
        else if (std.mem.startsWith(u8, name, "rules."))
            name[6..]
        else
            continue;

        const ws_num = std.fmt.parseInt(usize, ws_str, 10) catch continue;
        if (!validateWorkspace(ws_num, cfg.workspaces.count, name)) continue;

        var iter = entry.value_ptr.pairs.iterator();
        while (iter.next()) |class_entry| {
            try addRule(allocator, cfg, class_entry.key_ptr.*, ws_num);
        }
    }
}
