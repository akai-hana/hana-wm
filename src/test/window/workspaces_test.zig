//! Unit tests for the workspaces module (tag membership transitions +
//! workspace switching). Pure model transitions: none of the tested entry
//! points touch core.getState(), so they run headless (the config-driven
//! init/deinit path that forwards the workspace count to tracking is
//! exercised by the window-layer fixture's boot wiring, not here).

const std = @import("std");
const testing = std.testing;

const model = @import("model");
const constants = @import("constants");
const helpers = @import("helpers");
const build_options = @import("build_options");

const workspaces = if (build_options.has_workspaces) @import("workspaces") else struct {};

const max_ws = constants.max_workspaces;

test "moveWindowToWs relocates mask, home_ws, and tiled membership" {
    var m = helpers.makeModel();
    helpers.regCur(&m, 101); // home ws 0
    try testing.expectEqual(model.WSId.fromIndex(0), model.findHome(&m, 101).?);

    workspaces.moveWindowToWs(&m, 101, model.WSId.fromIndex(2));

    const e = m.store.get(101).?;
    try testing.expectEqual(model.bit(model.WSId.fromIndex(2)), e.mask);
    try testing.expectEqual(@as(?model.WSId, model.WSId.fromIndex(2)), e.home_ws);
    try testing.expectEqual(model.WSId.fromIndex(2), model.findHome(&m, 101).?);
    try testing.expectEqual(@as(usize, 1), m.ws[2].tiled_order.len);
    try testing.expectEqual(@as(usize, 0), m.ws[0].tiled_order.len);
}

test "moveWindowToWs: out-of-range workspace is a no-op (never indexes m.ws[ws])" {
    var m = helpers.makeModel();
    helpers.regCur(&m, 202);
    const before_mask = m.store.get(202).?.mask;

    // C12-era regression: the guard `ws >= m.ws.len` keeps these from
    // indexing m.ws[ws] out of bounds; without it ReleaseFast would take the
    // adjacent memory silently.
    workspaces.moveWindowToWs(&m, 202, model.WSId.fromIndex(@intCast(max_ws))); // == m.ws.len
    workspaces.moveWindowToWs(&m, 202, model.WSId.fromIndex(@intCast(constants.max_workspace_number_1based)));
    workspaces.moveWindowToWs(&m, 202, model.WSId.fromIndex(std.math.maxInt(u8)));

    try testing.expectEqual(before_mask, m.store.get(202).?.mask);
    try testing.expectEqual(model.WSId.fromIndex(0), model.findHome(&m, 202).?);
    try testing.expectEqual(@as(usize, 1), m.ws[0].tiled_order.len);
}

test "moveWindowToWs: pinned ALL_MASK window stays put" {
    var m = helpers.makeModel();
    helpers.regCur(&m, 303);
    workspaces.pinToggle(&m, 303);
    try testing.expectEqual(model.ALL_MASK, m.store.get(303).?.mask);

    workspaces.moveWindowToWs(&m, 303, model.WSId.fromIndex(1));

    try testing.expectEqual(model.ALL_MASK, m.store.get(303).?.mask);
    try testing.expectEqual(model.WSId.fromIndex(0), model.findHome(&m, 303).?);
}

test "moveWindowToWs: full destination list cancels the move before any mutation" {
    var m = helpers.makeModel();
    helpers.regCur(&m, 404); // stays on ws 0; the destination stays full
    for (0..model.max_tiled_per_ws) |i| {
        model.register(&m, @as(model.WindowId, @intCast(500 + i)), model.WSId.fromIndex(1)) catch unreachable;
    }
    try testing.expectEqual(@as(usize, model.max_tiled_per_ws), m.ws[1].tiled_order.len);

    const before = m.store.get(404).?.mask;
    workspaces.moveWindowToWs(&m, 404, model.WSId.fromIndex(1));

    try testing.expectEqual(before, m.store.get(404).?.mask);
    try testing.expectEqual(model.WSId.fromIndex(0), model.findHome(&m, 404).?);
    try testing.expectEqual(@as(usize, model.max_tiled_per_ws), m.ws[1].tiled_order.len);
}

test "tagRemove protects the last remaining tag; absent tags are refused too" {
    var m = helpers.makeModel();
    helpers.regCur(&m, 601); // single tag ws 0

    try testing.expect(!workspaces.tagRemove(&m, 601, model.WSId.fromIndex(0)));
    try testing.expectEqual(model.bit(model.WSId.fromIndex(0)), m.store.get(601).?.mask);
    try testing.expect(!workspaces.tagRemove(&m, 601, model.WSId.fromIndex(2))); // untagged ws also refused
    try testing.expectEqual(model.bit(model.WSId.fromIndex(0)), m.store.get(601).?.mask);
}

test "tagRemove clears a secondary tag" {
    var m = helpers.makeModel();
    helpers.regCur(&m, 601);
    workspaces.tagAdd(&m, 601, model.WSId.fromIndex(2), false);
    try testing.expectEqual(model.bit(model.WSId.fromIndex(0)) | model.bit(model.WSId.fromIndex(2)), m.store.get(601).?.mask);

    try testing.expect(workspaces.tagRemove(&m, 601, model.WSId.fromIndex(2)));

    try testing.expectEqual(model.bit(model.WSId.fromIndex(0)), m.store.get(601).?.mask);
}

test "tagAdd adds the target bit and optionally protects the current workspace" {
    var m = helpers.makeModel();
    helpers.regCur(&m, 701);
    workspaces.switchTo(&m, model.WSId.fromIndex(3));

    workspaces.tagAdd(&m, 701, model.WSId.fromIndex(1), false);
    try testing.expectEqual(model.bit(model.WSId.fromIndex(0)) | model.bit(model.WSId.fromIndex(1)), m.store.get(701).?.mask);

    workspaces.tagAdd(&m, 701, model.WSId.fromIndex(2), true); // adds ws 2 AND current ws 3
    try testing.expectEqual(
        model.bit(model.WSId.fromIndex(0)) | model.bit(model.WSId.fromIndex(1)) | model.bit(model.WSId.fromIndex(2)) | model.bit(model.WSId.fromIndex(3)),
        m.store.get(701).?.mask,
    );
}

test "pinToggle toggles ALL_MASK; allViewToggle flips the flag" {
    var m = helpers.makeModel();
    helpers.regCur(&m, 801);

    try testing.expect(!m.all_view_active);
    try testing.expect(workspaces.allViewToggle(&m));
    try testing.expect(!workspaces.allViewToggle(&m));

    workspaces.pinToggle(&m, 801);
    try testing.expectEqual(model.ALL_MASK, m.store.get(801).?.mask);
    workspaces.pinToggle(&m, 801);
    try testing.expectEqual(model.bit(model.WSId.fromIndex(0)), m.store.get(801).?.mask);
}

test "switchTo sets the current workspace" {
    var m = helpers.makeModel();
    workspaces.switchTo(&m, model.WSId.fromIndex(2));
    try testing.expectEqual(model.WSId.fromIndex(2), m.current);
}
