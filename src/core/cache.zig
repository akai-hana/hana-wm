//! Bar caching — workspace label pixel-widths.

const std     = @import("std");
const defs    = @import("defs");
const drawing = @import("drawing");

/// Caches per-workspace label pixel widths so the bar avoids redundant
/// Pango measurements on every draw call.  Embedded by value inside the bar
/// State struct (which is itself heap-allocated), so no separate allocation
/// is needed.
pub const CacheManager = struct {
    label_widths: [20]u16 = [_]u16{0} ** 20,
    valid:        bool    = false,

    /// Zero-initialised; call updateWorkspaceLabels() before first use.
    pub fn init() CacheManager { return .{}; }

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

    pub fn invalidate(self: *CacheManager) void { self.valid = false; }
};
