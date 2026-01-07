// Config parser

const std = @import("std");
const defs = @import("defs");
const Config = defs.Config;

pub fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !Config {
    // Read config file
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    // Get actual file size and allocate exactly that amount
    const file_size = (try file.stat()).size;
    const content = try file.readToEndAlloc(allocator, file_size);
    defer allocator.free(content);

    // Parse TOML (simple implementation)
    var parsed_config = Config{
        .border_width = 2,
        .border_color = 0xff0000,
    };

    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_number: usize = 0;
    while (lines.next()) |line| {
        line_number += 1;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
            const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
            const value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");

            // Handle empty values
            if (value.len == 0) {
                std.debug.print("Warning (line {}): Empty value for '{s}', using default\n", .{ line_number, key });
                continue;
            }

            if (std.mem.eql(u8, key, "border_width")) {
                const width = std.fmt.parseInt(u32, value, 10) catch |err| {
                    std.debug.print("Warning (line {}): Invalid border_width '{s}' ({}), using default\n", .{ line_number, value, err });
                    continue;
                };
                // Validate: no zero borders
                if (width == 0) {
                    std.debug.print("Warning (line {}): border_width cannot be 0, using default\n", .{line_number});
                } else {
                    parsed_config.border_width = width;
                }
            } else if (std.mem.eql(u8, key, "border_color")) {
                // Parse hex color (0xRRGGBB)
                const color = if (std.mem.startsWith(u8, value, "0x"))
                    std.fmt.parseInt(u32, value[2..], 16) catch |err| blk: {
                        std.debug.print("Warning (line {}): Invalid border_color '{s}' ({}), using default\n", .{ line_number, value, err });
                        break :blk null;
                    }
                else
                    std.fmt.parseInt(u32, value, 16) catch |err| blk: {
                        std.debug.print("Warning (line {}): Invalid border_color '{s}' ({}), using default\n", .{ line_number, value, err });
                        break :blk null;
                    };

                if (color) |c| {
                    parsed_config.border_color = c;
                }
            } else {
                // Unknown config key - warn about potential typo
                std.debug.print("Warning (line {}): Unknown config key '{s}' (ignored)\n", .{ line_number, key });
            }
        }
    }

    return parsed_config;
}
