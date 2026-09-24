//! Headless tests for the canonical workspace identifier (`core/utils/ids`).
//!
//! `WorkspaceId` unifies the former `core.WorkspaceId`+`model.WSId` pair, and
//! `fromIndex` now takes `anytype` with a checked internal cast so callers
//! don't scatter `@intCast` wrappers. These tests pin the index round-trip
//! and the wide-integer acceptance.

const std = @import("std");
const testing = std.testing;

const ids = @import("ids");

test "ids: fromIndex round-trips the index and eql compares it" {
    const a = ids.WorkspaceId.fromIndex(3);
    const b = ids.WorkspaceId.fromIndex(3);
    try testing.expectEqual(@as(u8, 3), a.index);
    try testing.expect(a.eql(b));
    try testing.expect(!a.eql(ids.WorkspaceId.fromIndex(4)));
}

test "ids: fromIndex accepts wider ints via the checked internal cast" {
    try testing.expectEqual(@as(u8, 5), ids.WorkspaceId.fromIndex(@as(u16, 5)).index);
}
