//! Bar caching — workspace label pixel-widths.
//!
//! The original CacheManager carried a color hashmap, dirty-flags, a config-hash
//! and several methods (getColor, markDirty, checkConfigChange) that were never
//! called from outside this module.  All dead code has been removed; only the
//! label-width cache (the sole external consumer) is retained.

const std    = @import("std");
const defs   = @import("defs");
const drawing = @import("drawing");

/// Caches per-workspace label pixel widths so the bar avoids redundant
/// Pango measurements on every draw call.
pub const CacheManager = struct {
    label_widths: [20]u16 = [_]u16{0} ** 20,
    valid:        bool    = false,
    allocator:    std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*CacheManager {
        const cm = try allocator.create(CacheManager);
        cm.* = .{ .allocator = allocator };
        return cm;
    }

    pub fn deinit(self: *CacheManager) void {
        self.allocator.destroy(self);
    }

    pub fn updateWorkspaceLabels(
        self:   *CacheManager,
        dc:     *drawing.DrawContext,
        config: *const defs.BarConfig,
    ) !void {
        if (self.valid) return;
        const static_numbers = [_][]const u8{
            "1", "2", "3", "4", "5", "6", "7", "8", "9", "10",
        };
        for (&self.label_widths, 0..) |*width, i| {
            const label: []const u8 =
                if (i < config.workspace_icons.items.len) config.workspace_icons.items[i]
                else if (i < static_numbers.len)          static_numbers[i]
                else                                      "?";
            width.* = dc.textWidth(label);
        }
        self.valid = true;
    }

    pub fn getWorkspaceLabelWidth(self: *const CacheManager, index: usize) u16 {
        if (!self.valid or index >= self.label_widths.len) return 0;
        return self.label_widths[index];
    }

    pub fn invalidate(self: *CacheManager) void {
        self.valid = false;
    }
};
