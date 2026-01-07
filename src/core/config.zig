// Config parser

const std = @import("std");
const defs = @import("defs");
const Config = defs.Config;

pub fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !Config {
    // Read config file
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    // Config files are small, 4KB is plenty
    const content = try file.readToEndAlloc(allocator, 4096);
    defer allocator.free(content);

    // Parse TOML (simple implementation)
    var parsed_config = Config{
        .border_width = 2,
        .border_color = 0xff0000,
    };

    var lines = std.mem.split(u8, content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
            const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
            const value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");

            if (std.mem.eql(u8, key, "border_width")) {
                const width = try std.fmt.parseInt(u32, value, 10);
                // Validate: no zero borders
                if (width == 0) {
                    std.debug.print("Warning: border_width cannot be 0, using default\n", .{});
                } else {
                    parsed_config.border_width = width;
                }
            } else if (std.mem.eql(u8, key, "border_color")) {
                // Parse hex color (0xRRGGBB)
                if (std.mem.startsWith(u8, value, "0x")) {
                    parsed_config.border_color = try std.fmt.parseInt(u32, value[2..], 16);
                } else {
                    parsed_config.border_color = try std.fmt.parseInt(u32, value, 16);
                }
            }
        }
    }

    return parsed_config;
}
