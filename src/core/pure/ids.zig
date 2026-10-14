//! Canonical workspace identifier type.
//!
//! `core.WorkspaceId` and `model.WSId` are both names for this single struct,
//! so workspace ids cross the core/model boundary without conversion. The type
//! keeps a `.index` member so model code can keep using ws values directly as
//! array indices; integer-typed boundaries (wire formats, counters) convert
//! with `fromIndex` / `.index`.
//! `fromIndex` accepts any integer (internal checked `@intCast` to u8), so
//! callers don't scatter `@intCast` wrappers; the u8 field type still keeps
//! indices distinct from unrelated u8 values (counts, layout indices, etc.).
//! Range is a SEPARATE question from representation: `fromIndex` is lenient
//! (config/recovery paths), `fromIndexChecked` asserts (internal paths), and
//! `isValid` is the single definition every fixed-size consumer asks.
//! Lives in core/pure (the xcb-free vocabulary) because both the hub and the
//! model need it and model must stay xcb-free (it never imports core); this
//! file imports nothing but std.
const std = @import("std");

const constants = @import("constants");

/// Canonical window identifier type (xcb_window_t / uint32_t). `core.WindowId`
/// and `model.WindowId` are aliases of this single definition (same precedent
/// as WorkspaceId), so window ids cross the core/model boundary without
/// conversion.
pub const WindowId = u32;

/// The ONE validity notion for a workspace index. Everything that has
/// to decide "is this index in range" -- the mask shift, the model's fixed-size
/// `ws` array, the config lookup tables -- asks here, so a raise of
/// `max_workspaces` cannot leave one of them answering a different question.
pub fn isValidWorkspaceIndex(i: anytype) bool {
    return @as(usize, @intCast(i)) < constants.max_workspaces;
}

pub const WorkspaceId = struct {
    index: u8,

    /// Lenient constructor: accepts any integer, narrowing to u8. This is the
    /// entry point the parser and restore paths use, and it deliberately does
    /// NOT range-check -- an out-of-range value from a user config is
    /// recoverable there (the caller clamps or skips with a warning), and a
    /// panic would turn a typo in a config file into a failed startup. Use
    /// `fromIndexChecked` where the value is internal and must be valid.
    pub fn fromIndex(i: anytype) WorkspaceId {
        return .{ .index = @intCast(i) };
    }

    /// Constructive constructor: asserts the index is a real workspace. Every
    /// INTERNAL site (model, mask, action dispatch) uses this, so a 65th
    /// workspace is a debug failure at the boundary that created it rather
    /// than a silent wrong-mask or an out-of-bounds array read further on.
    pub fn fromIndexChecked(i: anytype) WorkspaceId {
        const ws: WorkspaceId = .{ .index = @intCast(i) };
        std.debug.assert(isValidWorkspaceIndex(ws.index));
        return ws;
    }

    /// True when this id names a workspace the model can hold. A value past
    /// the ceiling can still exist (the lenient `fromIndex` admits it), so
    /// every consumer that indexes a fixed-size array must ask.
    pub fn isValid(self: WorkspaceId) bool {
        return isValidWorkspaceIndex(self.index);
    }

    pub fn eql(self: WorkspaceId, other: WorkspaceId) bool {
        return self.index == other.index;
    }
};
