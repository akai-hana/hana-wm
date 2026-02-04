/// Generic compile-time enum <-> string conversion
/// Eliminates boilerplate in enum definitions

const std = @import("std");

/// Generic compile-time enum <-> string conversion helper
/// Automatically generates string mapping from enum fields at compile time
pub fn EnumStringHelper(comptime T: type) type {
    return struct {
        const Self = @This();
        
        const map = blk: {
            const fields = @typeInfo(T).@"enum".fields;
            var entries: [fields.len]struct { []const u8, T } = undefined;
            for (fields, 0..) |field, i| {
                entries[i] = .{ field.name, @enumFromInt(field.value) };
            }
            break :blk std.StaticStringMap(T).initComptime(entries);
        };
        
        pub inline fn fromString(str: []const u8) ?T {
            return map.get(str);
        }
        
        pub inline fn toString(value: T) []const u8 {
            return @tagName(value);
        }
    };
}
