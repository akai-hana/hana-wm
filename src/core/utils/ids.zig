//! Canonical workspace identifier type.
//!
//! `core.WorkspaceId` used to be a `struct { index: u8 }` while `model.WSId`
//! was a raw `u16`, so every caller converted at the boundary (`@intCast` one
//! way, `.index` the other). Both now name this single struct: `core.WorkspaceId`
//! and `model.WSId` are the same type, so workspace ids cross the core/model
//! boundary without conversion. The type keeps a `.index` member so model
//! code can keep using ws values directly as array indices; integer-typed
//! boundaries (wire formats, counters) convert with `fromIndex` / `.index`.
//! `fromIndex` accepts any integer (internal checked `@intCast` to u8), so
//! callers don't scatter `@intCast` wrappers; the u8 field type still keeps
//! indices distinct from unrelated u8 values (counts, layout indices, etc.).
//! Lives in core/utils rather than core or model because both modules need it
//! and model must stay xcb-free (it never imports core); this file imports
//! nothing but std.
const std = @import("std");

/// Canonical window identifier type (xcb_window_t / uint32_t). `core.WindowId`
/// and `model.WindowId` are aliases of this single definition (same precedent
/// as WorkspaceId), so window ids cross the core/model boundary without
/// conversion.
pub const WindowId = u32;

pub const WorkspaceId = struct {
    index: u8,

    pub fn fromIndex(i: anytype) WorkspaceId {
        return .{ .index = @intCast(i) };
    }

    pub fn eql(self: WorkspaceId, other: WorkspaceId) bool {
        return self.index == other.index;
    }
};
