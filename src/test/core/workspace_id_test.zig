//! Headless tests for the canonical workspace identifier (model.WorkspaceId).
//!
//! `WorkspaceId` has a checked `fromIndex` that takes `anytype` so callers
//! don't scatter `@intCast` wrappers. These tests pin the index round-trip
//! and the wide-integer acceptance.

const std = @import("std");
const testing = std.testing;

const model = @import("model");

test "ids: fromIndex round-trips the index and eql compares it" {
    const a = model.WorkspaceId.fromIndex(3);
    const b = model.WorkspaceId.fromIndex(3);
    try testing.expectEqual(@as(u8, 3), a.index);
    try testing.expect(a.eql(b));
    try testing.expect(!a.eql(model.WorkspaceId.fromIndex(4)));
}

test "ids: fromIndex accepts wider ints via the checked internal cast" {
    try testing.expectEqual(@as(u8, 5), model.WorkspaceId.fromIndex(@as(u16, 5)).index);
}

// --- workspace validity: ONE notion -----------------------------

test "isValidWorkspaceIndex is the single range definition" {
    try testing.expect(model.isValidWorkspaceIndex(0));
    try testing.expect(model.isValidWorkspaceIndex(model.max_workspaces - 1));
    try testing.expect(!model.isValidWorkspaceIndex(model.max_workspaces));
    try testing.expect(!model.isValidWorkspaceIndex(255));
}

test "WorkspaceId.isValid agrees with the free function" {
    try testing.expect(model.WorkspaceId.fromIndex(3).isValid());
    // The lenient constructor admits an out-of-range value ON PURPOSE, so
    // this is the case every fixed-size consumer must check for itself.
    const oob = model.WorkspaceId.fromIndex(model.max_workspaces);
    try testing.expect(!oob.isValid());
    try testing.expectEqual(!model.isValidWorkspaceIndex(oob.index), !oob.isValid());
}

test "fromIndexChecked returns the index on the in-range path" {
    try testing.expectEqual(
        @as(u8, 5),
        model.WorkspaceId.fromIndexChecked(5).index,
    );
    // Its OTHER behavior -- panicking on an out-of-range index -- is
    // std.debug.assert and has no in-process pin (std.testing has no
    // expectPanic in 0.16; an out-of-range call would abort the test
    // binary). Panic-only contract: verified by construction, not assertion.
}
