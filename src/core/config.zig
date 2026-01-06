// Config parser

const std = @import("std");
const defs = @import("defs");
const Config = defs.Config;

pub fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !Config {
    // Read config file
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    // Parse TOML (simple implementation)
    var config = Config{
        .border_width = 2,
        .border_color = 0xff0000,
    };

    var lines = std.mem.split(u8, content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
            const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
            const value = std.mem.trim(u8, trimmed[eq_pos + 1..], " \t");

            if (std.mem.eql(u8, key, "border_width")) {
                config.border_width = try std.fmt.parseInt(u32, value, 10);
            } else if (std.mem.eql(u8, key, "border_color")) {
                // Parse hex color (0xRRGGBB)
                if (std.mem.startsWith(u8, value, "0x")) {
                    config.border_color = try std.fmt.parseInt(u32, value[2..], 16);
                } else {
                    config.border_color = try std.fmt.parseInt(u32, value, 16);
                }
            }
        }
    }

    return config;
}
