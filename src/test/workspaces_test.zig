//! Unit tests for per-workspace config-override resolution (ND-10):
//! duplicate entries for one workspace must resolve LAST-WINS uniformly
//! across variant and master-count lookups.

const std = @import("std");
const testing = std.testing;
const types = @import("types");
const workspaces = @import("workspaces");

test "duplicate master-count overrides: last wins" {
    var cfg = types.TilingConfig{};
    defer cfg.deinit(testing.allocator);

    try cfg.workspace_master_count_overrides.append(testing.allocator, .{ .workspace_idx = 0, .count = 1 });
    try cfg.workspace_master_count_overrides.append(testing.allocator, .{ .workspace_idx = 0, .count = 3 });

    var wss = [_]workspaces.Workspace{ workspaces.Workspace.init(0), workspaces.Workspace.init(1) };
    workspaces.applyWorkspaceOverrides(&wss, &cfg);

    try testing.expectEqual(@as(?u8, 3), wss[0].master_count);
    try testing.expectEqual(@as(?u8, null), wss[1].master_count);
}

test "duplicate layout overrides: last variant wins" {
    var cfg = types.TilingConfig{};
    defer cfg.deinit(testing.allocator);

    // Two override rows for ws 0: the second (monocle/gaps) must win.
    try cfg.workspace_layout_overrides.append(testing.allocator, .{
        .workspace_idx = 0,
        .layout_idx = 0,
        .variant = .{ .master = .fifo },
    });
    try cfg.workspace_layout_overrides.append(testing.allocator, .{
        .workspace_idx = 0,
        .layout_idx = 0,
        .variant = .{ .monocle = .gaps },
    });

    var wss = [_]workspaces.Workspace{workspaces.Workspace.init(0)};
    workspaces.applyWorkspaceOverrides(&wss, &cfg);

    const v = wss[0].variants orelse return error.TestUnexpectedNull;
    try testing.expect(v == .monocle);
    try testing.expectEqual(types.MonocleVariant.gaps, v.monocle);
}

test "out-of-range workspace indices are ignored" {
    var cfg = types.TilingConfig{};
    defer cfg.deinit(testing.allocator);

    try cfg.workspace_master_count_overrides.append(testing.allocator, .{ .workspace_idx = 200, .count = 5 });
    try cfg.workspace_layout_overrides.append(testing.allocator, .{ .workspace_idx = 200, .layout_idx = 0, .variant = null });

    var wss = [_]workspaces.Workspace{workspaces.Workspace.init(0)};
    workspaces.applyWorkspaceOverrides(&wss, &cfg);

    try testing.expectEqual(@as(?u8, null), wss[0].master_count);
    try testing.expectEqual(@as(?types.LayoutVariantOverride, null), wss[0].variants);
}
