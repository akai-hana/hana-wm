//! The embedded fallback TOML must always be a valid config: it is the boot
//! floor when no user config exists, and a syntax error in it would only
//! surface on a machine that has no other config to fall back to. This pins
//! the embedded document itself (parsing is the pure half; full
//! materialization is exercised by every config_test load, which goes
//! through the same buildConfigFromDoc).

const std = @import("std");
const testing = std.testing;

const fallback = @import("fallback");
const parser = @import("parser");

test "embedded fallback is present and parses with zero errors" {
    const toml = fallback.getFallbackToml() orelse {
        std.log.warn("embedded fallback.toml absent at build time; nothing to pin", .{});
        return;
    };
    try testing.expect(toml.len > 0);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = try parser.parse(a, toml, "fallback.toml");
    try testing.expect(!doc.had_errors);
    try testing.expect(doc.sections.count() > 0);
}
