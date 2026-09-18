//! Canonical workspace identifier type.
//!
//! `core.WorkspaceId` used to be a `struct { index: u8 }` while `model.WSId`
//! was a raw `u16`, so every caller converted at the boundary (`@intCast` one
//! way, `.index` the other). Both now name this single struct: `core.WorkspaceId`
//! and `model.WSId` are the same type, so workspace ids cross the core/model
//! boundary without conversion. The type keeps a `.index` member so model
//! code can keep using ws values directly as array indices; integer-typed
//! boundaries (wire formats, counters) convert with `fromIndex` / `.index`.
//! Lives in core/utils rather than core or model because both modules need it
//! and model must stay xcb-free (it never imports core); this file imports
//! nothing but std.
const std = @import("std");

pub const WorkspaceId = struct {
    index: u8,

    pub fn fromIndex(i: u8) WorkspaceId {
        return .{ .index = i };
    }

    pub fn eql(self: WorkspaceId, other: WorkspaceId) bool {
        return self.index == other.index;
    }
};

test "ids: fromIndex round-trips the index and eql compares it" {
    const a = WorkspaceId.fromIndex(3);
    const b = WorkspaceId.fromIndex(3);
    try std.testing.expectEqual(@as(u8, 3), a.index);
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(WorkspaceId.fromIndex(4)));
}
