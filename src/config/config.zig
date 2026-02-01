//! Configuration interpreter

const std = @import("std");
const defs = @import("defs");
const parser = @import("parser");
const xkb = @import("xkbcommon");

// Consolidated color parsing
pub fn parseColor(str: []const u8) !u32 {
    if (str.len == 0) return error.InvalidColor;

    const offset: usize = if (str[0] == '#') 1 else if (str.len > 2 and str[0] == '0' and (str[1] == 'x' or str[1] == 'X')) 2 else 0;
    const hex_part = str[offset..];

    if (hex_part.len == 0) return error.InvalidColor;

    const color = std.fmt.parseInt(u32, hex_part, 16) catch return error.InvalidColor;
    if (color > 0xFFFFFF) return error.InvalidColor;

    return color;
}

fn getColor(section: *const parser.Section, key: []const u8, default: u32) u32 {
    const value = section.get(key) orelse return default;

    if (value.asColor()) |color| {
        return if (color <= 0xFFFFFF) color else default;
    }

    if (value.asString()) |str| {
        const color = parseColor(str) catch {
            std.log.warn("[config] Invalid color for {s}: '{s}'", .{ key, str });
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
        u16, u32, usize => blk: {
            const i = section.getInt(key) orelse return default;
            break :blk @as(T, @intCast(i));
        },
        else => @compileError("Unsupported type"),
    };

    // Validate bounds and warn if out of range
    if (comptime min != null or max != null) {
        var out_of_bounds = false;
        
        if (comptime min) |m| {
            if (value < m) {
                std.log.warn("[config] Value for '{s}' ({any}) below minimum ({any}), using default ({any})", 
                    .{key, value, m, default});
                out_of_bounds = true;
            }
        }
        
        if (comptime max) |m| {
            if (value > m) {
                std.log.warn("[config] Value for '{s}' ({any}) above maximum ({any}), using default ({any})", 
                    .{key, value, m, default});
                out_of_bounds = true;
            }
        }
        
        if (out_of_bounds) return default;
    }

    return value;
}

pub fn loadConfigDefault(allocator: std.mem.Allocator) !defs.Config {
    // First, try ~/.config/hana/config.toml (XDG_CONFIG_HOME or ~/.config)
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
        // Second, try ./config.toml in current directory
        const cwd = try std.process.getCwdAlloc(allocator);
        defer allocator.free(cwd);

        const local = try std.fs.path.join(allocator, &.{ cwd, "config.toml" });
        defer allocator.free(local);

        if (loadConfig(allocator, local)) |cfg| {
            return cfg;
        } else |_| {
            // Finally, use embedded fallback with auto-detection
            std.log.info("[config] No config.toml found, using fallback with auto-detection", .{});
            return try loadFallbackConfig(allocator);
        }
    }
}

pub fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !defs.Config {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const fd = std.posix.open(path_z, .{ .ACCMODE = .RDONLY }, 0) catch |err| {
        if (err == error.FileNotFound) {
            std.log.info("[config] Not found: {s}", .{path});
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

    // Check if file is empty
    if (content.items.len == 0) {
        std.log.info("[config] Empty config file: {s}, using fallback", .{path});
        return try loadFallbackConfig(allocator);
    }

    var doc = try parser.parse(allocator, content.items);
    defer doc.deinit();

    var cfg = getDefaultConfig(allocator);

    parseWorkspaces(&doc, &cfg);
    try parseKeybindings(allocator, &doc, &cfg);
    try parseTiling(allocator, &doc, &cfg);
    try parseBar(allocator, &doc, &cfg);
    try parseRules(allocator, &doc, &cfg);

    std.log.info("[config] Loaded: {s}", .{path});
    return cfg;
}

/// Load fallback configuration with auto-detection of terminal and font
fn loadFallbackConfig(allocator: std.mem.Allocator) !defs.Config {
    const fallback = @import("fallback");
    const fallback_toml = fallback.getFallbackToml();
    
    var doc = try parser.parse(allocator, fallback_toml);
    defer doc.deinit();

    var cfg = getDefaultConfig(allocator);

    parseWorkspaces(&doc, &cfg);
    try parseKeybindings(allocator, &doc, &cfg);
    try parseTiling(allocator, &doc, &cfg);
    try parseBar(allocator, &doc, &cfg);
    try parseRules(allocator, &doc, &cfg);

    // Auto-detect terminal and replace "auto_terminal" action
    const terminal = try fallback.detectTerminal(allocator);
    for (cfg.keybindings.items) |*kb| {
        if (kb.action == .exec) {
            if (std.mem.eql(u8, kb.action.exec, "auto_terminal")) {
                allocator.free(kb.action.exec);
                kb.action.exec = try allocator.dupe(u8, terminal);
            }
        }
    }

    // Auto-detect font if set to "auto"
    if (std.mem.eql(u8, cfg.bar.font, "auto")) {
        const detected_font = try fallback.detectFont(allocator);
        const font_with_size = try std.fmt.allocPrint(allocator, "{s}:size={}", .{detected_font, cfg.bar.font_size});
        // Note: the default font string will be freed by Config.deinit, so we don't allocate it in getDefaultConfig
        cfg.bar.font = font_with_size;
    }

    std.log.info("[config] Loaded fallback configuration with auto-detection", .{});
    return cfg;
}

fn getDefaultConfig(allocator: std.mem.Allocator) defs.Config {
    var cfg = defs.Config.init(allocator);
    
    // Set default workspace icons
    for (0..9) |i| {
        const icon = std.fmt.allocPrint(allocator, "{}", .{i + 1}) catch continue;
        cfg.bar.workspace_icons.append(allocator, icon) catch {};
    }
    
    // Set default layout
    var default_layout = defs.BarLayout{
        .position = .left,
        .segments = std.ArrayList(defs.BarSegment){},
    };
    default_layout.segments.append(allocator, .workspaces) catch {};
    cfg.bar.layout.append(allocator, default_layout) catch {};
    
    var center_layout = defs.BarLayout{
        .position = .center,
        .segments = std.ArrayList(defs.BarSegment){},
    };
    center_layout.segments.append(allocator, .title) catch {};
    cfg.bar.layout.append(allocator, center_layout) catch {};
    
    var right_layout = defs.BarLayout{
        .position = .right,
        .segments = std.ArrayList(defs.BarSegment){},
    };
    right_layout.segments.append(allocator, .clock) catch {};
    cfg.bar.layout.append(allocator, right_layout) catch {};
    
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
    .{ "kill", .close_window },
    .{ "reload", .reload_config },
    .{ "reload_config", .reload_config },
    .{ "toggle_layout", .toggle_layout },
    .{ "toggle_layout_reverse", .toggle_layout_reverse },
    .{ "toggle_bar", .toggle_bar },
    .{ "increase_master", .increase_master },
    .{ "decrease_master", .decrease_master },
    .{ "increase_master_count", .increase_master_count },
    .{ "decrease_master_count", .decrease_master_count },
    .{ "toggle_tiling", .toggle_tiling },
    .{ "toggle_fullscreen", .toggle_fullscreen },
    .{ "fullscreen", .toggle_fullscreen },
    .{ "dump_state", .dump_state },
    .{ "emergency_recover", .emergency_recover },
});

fn parseKeybindings(allocator: std.mem.Allocator, doc: *const parser.Document, cfg: *defs.Config) !void {
    const section = doc.getSection("Keybindings") orelse return;
    const mod_substitute = section.getString("Mod");

    var iter = section.pairs.iterator();
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "Mod")) continue;

        const command = entry.value_ptr.*.asString() orelse continue;

        const keybind_str = if (mod_substitute) |mod|
            try substituteModVariable(allocator, entry.key_ptr.*, mod)
        else
            entry.key_ptr.*;
        defer if (mod_substitute != null) allocator.free(keybind_str);

        const parts = parseKeybindString(keybind_str) catch |err| {
            std.log.warn("[config] Failed to parse keybind '{s}': {}", .{ keybind_str, err });
            continue;
        };
        const action = try parseAction(allocator, command);

        try cfg.keybindings.append(allocator, .{
            .modifiers = parts.modifiers,
            .keysym = parts.keysym,
            .action = action,
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

fn parseAction(allocator: std.mem.Allocator, cmd: []const u8) !defs.Action {
    if (ACTION_MAP.get(cmd)) |action| return action;

    if (std.mem.startsWith(u8, cmd, "workspace_")) {
        const num = try std.fmt.parseInt(usize, cmd[10..], 10);
        if (num < 1 or num > defs.MAX_WORKSPACES) return error.InvalidWorkspace;
        return .{ .switch_workspace = num - 1 };
    }

    if (std.mem.startsWith(u8, cmd, "move_to_workspace_")) {
        const num = try std.fmt.parseInt(usize, cmd[18..], 10);
        if (num < 1 or num > defs.MAX_WORKSPACES) return error.InvalidWorkspace;
        return .{ .move_to_workspace = num - 1 };
    }

    return .{ .exec = try allocator.dupe(u8, cmd) };
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
            std.log.warn("[config] Keybinding conflict detected!", .{});
            std.log.warn("  Binding #{}: mods=0x{x:0>4} key={} (first)", .{
                first_index + 1, keybindings[first_index].modifiers, keycode
            });
            std.log.warn("  Binding #{}: mods=0x{x:0>4} key={} (duplicate)", .{
                i + 1, kb.modifiers, keycode
            });
            std.log.warn("  The second binding will override the first!", .{});
        } else {
            seen.put(key, i) catch {};
        }
    }
}

fn parseTiling(allocator: std.mem.Allocator, doc: *const parser.Document, cfg: *defs.Config) !void {
    const section = doc.getSection("tiling") orelse return;

    cfg.tiling.enabled = get(bool, section, "enabled", true, null, null);

    const layout_str = get([]const u8, section, "layout", "master_left", null, null);
    cfg.allocated_layout = try allocator.dupe(u8, layout_str);
    cfg.tiling.layout = cfg.allocated_layout.?;

    if (section.getString("master_side")) |side_str| {
        cfg.tiling.master_side = defs.MasterSide.fromString(side_str) orelse .left;
    }

    cfg.tiling.master_count = get(usize, section, "master_count", 1, 1, null);
    cfg.tiling.master_width_factor = get(f32, section, "master_width_factor", 50.0, defs.MIN_MASTER_WIDTH, defs.MAX_MASTER_WIDTH);
    cfg.tiling.gaps = get(u16, section, "gaps", 10, 0, defs.MAX_GAPS);
    cfg.tiling.border_width = get(u16, section, "border_width", 2, 0, defs.MAX_BORDER_WIDTH);

    cfg.tiling.border_focused = getColor(section, "border_focused", 0x5294E2);
    cfg.tiling.border_normal = getColor(section, "border_normal", 0x383C4A);
}

fn parseBar(allocator: std.mem.Allocator, doc: *const parser.Document, cfg: *defs.Config) !void {
    const section = doc.getSection("bar") orelse return;

    cfg.bar.show = get(bool, section, "show", true, null, null);
    
    // Parse vertical position (top/bottom)
    if (section.getString("position")) |pos_str| {
        cfg.bar.vertical_position = defs.BarVerticalPosition.fromString(pos_str) orelse .top;
    }
    
    // Height can be null for auto-adapt
    if (section.getInt("height")) |h| {
        cfg.bar.height = @intCast(std.math.clamp(h, 16, 100));
    }

    const font_str = get([]const u8, section, "font", "monospace:size=10", null, null);
    cfg.allocated_font = try allocator.dupe(u8, font_str);
    cfg.bar.font = cfg.allocated_font.?;

    // Parse fonts array for multi-font support (CJK, etc.)
    if (section.get("fonts")) |value| {
        if (value.asArray()) |arr| {
            // Clear any existing fonts
            for (cfg.bar.fonts.items) |font| {
                allocator.free(font);
            }
            cfg.bar.fonts.clearRetainingCapacity();
            
            // Load fonts from array
            for (arr) |item| {
                if (item.asString()) |font_name| {
                    const font_copy = try allocator.dupe(u8, font_name);
                    try cfg.bar.fonts.append(allocator, font_copy);
                }
            }
            std.log.info("[config] Loaded {} fonts for bar", .{cfg.bar.fonts.items.len});
        }
    }

    cfg.bar.font_size = get(u16, section, "font_size", 10, 6, 72);
    cfg.bar.padding = get(u16, section, "padding", 8, 0, 50);
    cfg.bar.spacing = get(u16, section, "spacing", 12, 0, 100);

    cfg.bar.bg = getColor(section, "bg", 0x222222);
    cfg.bar.fg = getColor(section, "fg", 0xBBBBBB);
    cfg.bar.selected_bg = getColor(section, "selected_bg", 0x005577);
    cfg.bar.selected_fg = getColor(section, "selected_fg", 0xEEEEEE);
    cfg.bar.occupied_fg = getColor(section, "occupied_fg", 0xEEEEEE);
    cfg.bar.urgent_bg = getColor(section, "urgent_bg", 0xFF0000);
    cfg.bar.urgent_fg = getColor(section, "urgent_fg", 0xFFFFFF);
    
    // Accent colors
    cfg.bar.accent_color = getColor(section, "accent_color", 0x61AFEF);
    if (section.get("workspaces_accent")) |_| {
        cfg.bar.workspaces_accent = getColor(section, "workspaces_accent", cfg.bar.accent_color);
    }
    if (section.get("title_accent_color")) |_| {
        cfg.bar.title_accent_color = getColor(section, "title_accent_color", cfg.bar.accent_color);
    }
    if (section.get("clock_accent")) |_| {
        cfg.bar.clock_accent = getColor(section, "clock_accent", cfg.bar.accent_color);
    }

    // Clock format
    const clock_fmt = get([]const u8, section, "clock_format", "%Y-%m-%d %H:%M:%S", null, null);
    cfg.allocated_clock_format = try allocator.dupe(u8, clock_fmt);
    cfg.bar.clock_format = cfg.allocated_clock_format.?;

    cfg.bar.indicator_size = get(u16, section, "indicator_size", 4, 2, 10);
    cfg.bar.title_accent = get(bool, section, "title_accent", true, null, null);
    
    // Parse workspace icons
    try parseWorkspaceIcons(allocator, section, cfg);
    
    // Parse bar layout
    try parseBarLayout(allocator, section, doc, cfg);
    
    // Parse per-segment colors from bar.colors section
    if (doc.getSection("bar.colors")) |colors_section| {
        if (colors_section.get("workspaces")) |_| {
            cfg.bar.workspaces_accent = getColor(colors_section, "workspaces", cfg.bar.accent_color);
        }
        if (colors_section.get("title")) |_| {
            cfg.bar.title_accent_color = getColor(colors_section, "title", cfg.bar.accent_color);
        }
        if (colors_section.get("clock")) |_| {
            cfg.bar.clock_accent = getColor(colors_section, "clock", cfg.bar.accent_color);
        }
    }
}

fn parseWorkspaceIcons(allocator: std.mem.Allocator, section: *const parser.Section, cfg: *defs.Config) !void {
    // Clear defaults
    for (cfg.bar.workspace_icons.items) |icon| {
        allocator.free(icon);
    }
    cfg.bar.workspace_icons.clearRetainingCapacity();
    
    if (section.get("icons")) |value| {
        if (value.asArray()) |arr| {
            // Array of strings
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
            // String of characters (old format)
            for (str) |ch| {
                const icon = try std.fmt.allocPrint(allocator, "{c}", .{ch});
                try cfg.bar.workspace_icons.append(allocator, icon);
            }
        }
    }
    
    // Fill remaining with numbers if needed
    const ws_count = cfg.workspaces.count;
    while (cfg.bar.workspace_icons.items.len < ws_count) {
        const idx = cfg.bar.workspace_icons.items.len;
        const icon = try std.fmt.allocPrint(allocator, "{}", .{idx + 1});
        try cfg.bar.workspace_icons.append(allocator, icon);
    }
}

fn parseBarLayout(allocator: std.mem.Allocator, section: *const parser.Section, doc: *const parser.Document, cfg: *defs.Config) !void {
    // Clear defaults
    for (cfg.bar.layout.items) |*item| {
        item.deinit(allocator);
    }
    cfg.bar.layout.clearRetainingCapacity();
    
    // Try to parse layout array
    if (section.get("layout")) |value| {
        if (value.asArray()) |layout_arr| {
            for (layout_arr) |_| {
                // Each item should be a table with position and segments
                // Since we can't easily parse inline tables, we'll use a workaround
                // Users can define [bar.layout.0], [bar.layout.1], etc.
                std.log.warn("[config] bar.layout array parsing not yet fully supported, use sections like [bar.layout.left]", .{});
            }
        }
    }
    
    // Try to parse layout sections: [bar.layout.left], [bar.layout.center], [bar.layout.right]
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
    
    // If no layout was parsed, use defaults
    if (cfg.bar.layout.items.len == 0) {
        var left_layout = defs.BarLayout{
            .position = .left,
            .segments = std.ArrayList(defs.BarSegment){},
        };
        try left_layout.segments.append(allocator, .workspaces);
        try cfg.bar.layout.append(allocator, left_layout);
        
        var center_layout = defs.BarLayout{
            .position = .center,
            .segments = std.ArrayList(defs.BarSegment){},
        };
        try center_layout.segments.append(allocator, .title);
        try cfg.bar.layout.append(allocator, center_layout);
        
        var right_layout = defs.BarLayout{
            .position = .right,
            .segments = std.ArrayList(defs.BarSegment){},
        };
        try right_layout.segments.append(allocator, .clock);
        try cfg.bar.layout.append(allocator, right_layout);
    }
}

fn parseWorkspaces(doc: *const parser.Document, cfg: *defs.Config) void {
    const section = doc.getSection("workspaces") orelse return;
    cfg.workspaces.count = get(usize, section, "count", 9, defs.MIN_WORKSPACES, defs.MAX_WORKSPACES);
}

fn parseRules(allocator: std.mem.Allocator, doc: *const parser.Document, cfg: *defs.Config) !void {
    if (doc.getSection("rules")) |section| {
        var iter = section.pairs.iterator();
        while (iter.next()) |entry| {
            const ws_num = entry.value_ptr.*.asInt() orelse continue;

            if (ws_num < 1 or ws_num > cfg.workspaces.count) {
                std.log.warn("[config] Rule workspace {} for '{s}' exceeds count {}, skipping", .{ ws_num, entry.key_ptr.*, cfg.workspaces.count });
                continue;
            }

            const rule = defs.Rule{
                .class_name = try allocator.dupe(u8, entry.key_ptr.*),
                .workspace = @intCast(ws_num - 1),
            };
            try cfg.workspaces.rules.append(allocator, rule);
        }
    }

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

        if (ws_num < 1 or ws_num > cfg.workspaces.count) {
            std.log.warn("[config] Section '{s}' workspace {} exceeds count {}, skipping", .{ name, ws_num, cfg.workspaces.count });
            continue;
        }

        var iter = entry.value_ptr.pairs.iterator();
        while (iter.next()) |class_entry| {
            const rule = defs.Rule{
                .class_name = try allocator.dupe(u8, class_entry.key_ptr.*),
                .workspace = ws_num - 1,
            };
            try cfg.workspaces.rules.append(allocator, rule);
        }
    }
}
