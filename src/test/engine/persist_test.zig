//! Persist module round-trip tests (F-10). The save wire format and the
//! model-level restore path are xcb-free, so they run headless; the full
//! save-on-quit / adopt-on-exec cycle needs the live X connection and is
//! covered end-to-end by the S22 harness scenario.
//!
//! `loadToGlobal` installs a process-lifetime global (`loaded_parsed`) with no
//! public free, so this suite loads state through `std.heap.page_allocator`:
//! the module-held parse is then untracked by the per-test leak check (it is
//! intentionally held for the whole process in production).
//!
//! `save` is called with the leak-checking `testing` allocator: the
//! core/persist.zig save path used to transfer the JSON buffer out of its
//! Allocating writer and never free it (an S-F finding, surfaced as leaked
//! bytes here), and the one-line fix that lands in core/persist.zig frees it
//! (`defer al.deinit()`), so the tracking allocator now doubles as a
//! regression guard for that class of leak.

const std = @import("std");
const testing = std.testing;

// Some restore/save paths log warn-level diagnostics; debug.zig silences
// all std.log diagnostics in test binaries, so this stays quiet on success.
const model = @import("model");
const persist = @import("persist");
const scratch = @import("scratch");
const helpers = @import("helpers");

const page_alloc = std.heap.page_allocator;

/// A deterministic, non-trivial model: three tiled windows spread over two
/// workspaces plus one floating window, with focus, reordered tiled order and
/// custom workspace params and per-ws runtime viewport state.
fn buildFixtureModel(m: *model.Model) void {
    model.register(m, 1, model.WSId.fromIndex(0)) catch unreachable;
    model.register(m, 2, model.WSId.fromIndex(0)) catch unreachable;
    model.register(m, 3, model.WSId.fromIndex(1)) catch unreachable;
    model.setFocus(m, 1);
    _ = m.store.put(4, .{
        .mask = model.bit(model.WSId.fromIndex(0)),
        .anchor = .{ .floating = .{ .x = 5, .y = 6, .width = 100, .height = 80 } },
    }) catch unreachable;
    model.reorderTiled(m, 2, 0); // ws 0 tiled order [2, 1]

    m.current = model.WSId.fromIndex(1);
    m.all_view_active = true;
    m.ws[0].params.primary_width = 0.6;
    m.ws[0].params.primary_count = 2;
    m.ws[1].params.viewport_offset = -1;
}

/// The window id set the restore path expects to see again (adoption would
/// re-register these after a re-exec). Window 4 floats and is deliberately
/// absent -- like a window that did not survive the re-exec.
fn registerSurvivors(m: *model.Model) void {
    model.register(m, 1, model.WSId.fromIndex(0)) catch unreachable;
    model.register(m, 2, model.WSId.fromIndex(0)) catch unreachable;
    model.register(m, 3, model.WSId.fromIndex(1)) catch unreachable;
}

test "F10: save/load keeps every window record and workspace field" {
    var src = helpers.makeModel();
    buildFixtureModel(&src);

    const path = try scratch.scratchPath(testing.allocator, "hana-persist-", "roundtrip");
    defer testing.allocator.free(path);
    try persist.save(testing.allocator, &src, path);
    defer scratch.cleanupScratch(path);

    try testing.expect(try persist.loadToGlobal(page_alloc, path));

    const recorded = persist.loaded().?;
    // loadToGlobal's own version gate already rejected the wrong-version file;
    // the round-trip record must carry the (internal, non-pub) version value.
    try testing.expect(recorded.version > 0);
    try testing.expectEqual(@as(u8, 1), recorded.current);
    try testing.expectEqual(@as(?model.WindowId, 1), recorded.focused);
    try testing.expect(recorded.all_view_active);

    // Store keys persist in sorted order: 1, 2, 3, 4.
    try testing.expectEqual(@as(usize, 4), recorded.windows.len);
    const w1 = recorded.windows[0];
    try testing.expectEqual(@as(model.WindowId, 1), w1.win);
    try testing.expectEqual(@as(model.Mask, model.bit(model.WSId.fromIndex(0))), w1.mask);
    try testing.expect(@intFromEnum(w1.anchor) == @intFromEnum(model.BaseMode.tiled));
    try testing.expect(w1.presence == .present);
    try testing.expect(w1.covering_ws == null);
    try testing.expectEqual(@as(model.WindowId, 3), recorded.windows[2].win);
    try testing.expectEqual(@as(model.WindowId, 4), recorded.windows[3].win);
    try testing.expect(@intFromEnum(recorded.windows[3].anchor) == @intFromEnum(model.BaseMode.floating));
    const fr = recorded.windows[3].anchor.floating;
    try testing.expectEqual(@as(i32, 5), fr.x);
    try testing.expectEqual(@as(i32, 6), fr.y);
    try testing.expectEqual(@as(i32, 100), fr.width);
    try testing.expectEqual(@as(i32, 80), fr.height);

    // Workspace records carry params, tiled order and mru.
    const ws0 = recorded.workspaces[0];
    try testing.expectEqual(@as(f32, 0.6), ws0.params.primary_width);
    try testing.expectEqual(@as(u8, 2), ws0.params.primary_count);
    try testing.expectEqualSlices(model.WindowId, &.{ 2, 1 }, ws0.tiled);
    try testing.expectEqualSlices(model.WindowId, &.{1}, ws0.mru);
    const ws1 = recorded.workspaces[1];
    try testing.expectEqual(@as(i32, -1), ws1.params.viewport_offset);
    try testing.expectEqualSlices(model.WindowId, &.{3}, ws1.tiled);
}

test "F10: loadToGlobal rejects a corrupt file and a bad version" {
    const bad = try scratch.scratchPath(testing.allocator, "hana-persist-", "corrupt");
    defer testing.allocator.free(bad);
    try scratch.writeScratchFile(bad, "not json at all");
    defer scratch.cleanupScratch(bad);

    try testing.expect(!try persist.loadToGlobal(page_alloc, bad));

    const wrong_version = try scratch.scratchPath(testing.allocator, "hana-persist-", "wrongver");
    defer testing.allocator.free(wrong_version);
    try scratch.writeScratchFile(wrong_version, "{ \"version\": 9999, \"current\": 0, \"windows\": [] }");
    defer scratch.cleanupScratch(wrong_version);

    try testing.expect(!try persist.loadToGlobal(page_alloc, wrong_version));

    // A missing path is not an error, just a clean "nothing to restore".
    const missing = try scratch.scratchPath(testing.allocator, "hana-persist-", "missing");
    defer testing.allocator.free(missing);
    try testing.expect(!try persist.loadToGlobal(page_alloc, missing));
}

test "F10: applyModelLevel restores focus, ws state and every membership" {
    var src = helpers.makeModel();
    buildFixtureModel(&src);

    const path = try scratch.scratchPath(testing.allocator, "hana-persist-", "apply");
    defer testing.allocator.free(path);
    try persist.save(testing.allocator, &src, path);
    defer scratch.cleanupScratch(path);
    try testing.expect(try persist.loadToGlobal(page_alloc, path));

    // The re-exec'd process redisovers its old windows and registers them
    // before the persisted model level is applied back.
    var restored = helpers.makeModel();
    registerSurvivors(&restored);

    persist.applyModelLevel(&restored);

    try testing.expectEqual(model.WSId.fromIndex(1), restored.current);
    try testing.expectEqual(@as(?model.WindowId, 1), restored.focused);
    try testing.expect(restored.all_view_active);
    try testing.expectEqualSlices(model.WindowId, &.{ 2, 1 }, restored.ws[0].tiled_order.constSlice());
    try testing.expectEqualSlices(model.WindowId, &.{1}, restored.ws[0].focus_mru.constSlice());
    try testing.expectEqualSlices(model.WindowId, &.{3}, restored.ws[1].tiled_order.constSlice());
    try testing.expectEqual(@as(f32, 0.6), restored.ws[0].params.primary_width);
    try testing.expectEqual(@as(u8, 2), restored.ws[0].params.primary_count);
    try testing.expectEqual(@as(i32, -1), restored.ws[1].params.viewport_offset);

    // Membership fully reconstructed: every window has a home workspace and
    // sits in exactly one tiled order / presence list.
    try testing.expectEqual(model.WSId.fromIndex(0), model.findHome(&restored, 1).?);
    try testing.expectEqual(model.WSId.fromIndex(0), model.findHome(&restored, 2).?);
    try testing.expectEqual(model.WSId.fromIndex(1), model.findHome(&restored, 3).?);
    try testing.expect(model.visibleOn(&restored, 1, model.findHome(&restored, 1).?));
    try testing.expect(model.visibleOn(&restored, 2, model.findHome(&restored, 2).?));
    try testing.expect(model.visibleOn(&restored, 3, model.findHome(&restored, 3).?));
}
