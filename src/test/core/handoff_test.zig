//! Persist module round-trip tests. The save wire format and the
//! model-level restore path are xcb-free, so they run headless; the full
//! save-on-quit / adopt-on-exec cycle needs the live X connection and is
//! covered end-to-end by the restore harness scenario.
//!
//! `loadToGlobal` installs a process-lifetime global (`loaded_parsed`) with no
//! public free, so this suite loads state through `std.heap.page_allocator`:
//! the module-held parse is then untracked by the per-test leak check (it is
//! intentionally held for the whole process in production).
//!
//! `save` is called with the leak-checking `testing` allocator: the
//! core/proc/handoff.zig save path used to transfer the JSON buffer out of its
//! Allocating writer and never free it (an S-F finding, surfaced as leaked
//! bytes here), and the one-line fix that lands in core/proc/handoff.zig frees it
//! (`defer al.deinit()`), so the tracking allocator now doubles as a
//! regression guard for that class of leak.

const std = @import("std");
const testing = std.testing;

// Some restore/save paths log warn-level diagnostics; debug.zig silences
// all std.log diagnostics in test binaries, so this stays quiet on success.
const model = @import("model");
const handoff = @import("handoff");
const scratch = @import("scratch");
const helpers = @import("helpers");

const page_alloc = std.heap.page_allocator;

/// A deterministic, non-trivial model: three tiled windows spread over two
/// workspaces plus one floating window, with focus, reordered tiled order and
/// custom workspace params and per-ws runtime viewport state.
fn buildFixtureModel(m: *model.Model) !void {
    try model.register(m, 1, model.WSId.fromIndex(0));
    try model.register(m, 2, model.WSId.fromIndex(0));
    try model.register(m, 3, model.WSId.fromIndex(1));
    model.setFocus(m, 1);
    _ = try m.store.put(4, .{
        .mask = model.bit(model.WSId.fromIndex(0)),
        .anchor = .{ .floating = .{ .x = 5, .y = 6, .width = 100, .height = 80 } },
    });
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
fn registerSurvivors(m: *model.Model) !void {
    try model.register(m, 1, model.WSId.fromIndex(0));
    try model.register(m, 2, model.WSId.fromIndex(0));
    try model.register(m, 3, model.WSId.fromIndex(1));
}

test "F10: save/load keeps every window record and workspace field" {
    var src = helpers.makeModel();
    try buildFixtureModel(&src);

    // (28.5) per-test tmpDir; TmpFile.cleanup removes the file with its dir.
    var f = try scratch.TmpFile.init("roundtrip.hana-state");
    defer f.deinit();
    try f.write("");
    try handoff.save(testing.allocator, &src, f.path());

    try testing.expect(handoff.loadToGlobal(page_alloc, f.path()));

    const recorded = handoff.loaded().?;
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
    // (28.5) each file gets its own tmpDir.
    var bad = try scratch.TmpFile.init("corrupt");
    defer bad.deinit();
    try bad.write("not json at all");

    // Failure path must not touch the retained parse: the global before each
    // rejected attempt is the state the WM keeps. Asserting against handoff.loaded()
    // here makes "a failed load leaves the last good state intact" an actual
    // invariant rather than a hope.
    const retained = handoff.loaded();

    try testing.expect(!handoff.loadToGlobal(page_alloc, bad.path()));
    try testing.expect(handoff.loaded() == retained);

    var wrong_version = try scratch.TmpFile.init("wrong_version");
    defer wrong_version.deinit();
    try wrong_version.write("{ \"version\": 9999, \"current\": 0, \"windows\": [] }");

    try testing.expect(!handoff.loadToGlobal(page_alloc, wrong_version.path()));
    try testing.expect(handoff.loaded() == retained);

    // A missing path is not an error, just a clean "nothing to restore". The
    // path sits inside a real (merely unwritten) temp dir, so "missing" is
    // exercised as an absent FILE rather than an absent directory.
    var missing = try scratch.TmpFile.init("missing");
    defer missing.deinit();

    try testing.expect(!handoff.loadToGlobal(page_alloc, missing.path()));
    try testing.expect(handoff.loaded() == retained);
}

test "F10: applyModelLevel restores focus, ws state and every membership" {
    var src = helpers.makeModel();
    try buildFixtureModel(&src);

    var f = try scratch.TmpFile.init("apply"); // (28.5)
    defer f.deinit();
    try handoff.save(testing.allocator, &src, f.path());
    try testing.expect(handoff.loadToGlobal(page_alloc, f.path()));

    // The re-exec'd process redisovers its old windows and registers them
    // before the persisted model level is applied back.
    var restored = helpers.makeModel();
    try registerSurvivors(&restored);

    handoff.applyModelLevel(&restored);

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

// The per-window blob header changed from a 2-byte REGISTRY ORDINAL to a
// variable-length CLAIMANT NAME, because an ordinal is a position in a
// build-generated list: deleting or reordering an unrelated module renumbers
// everything after it, and a saved session's fast path then points at a
// different module. These pin both halves of the migration -- the new name
// header, and that an old ordinal-stamped blob is still read rather than
// silently dropped.

// (9.10) decodeExt is the ONE reader the header format has now -- the three
// separate accessors it replaced are gone -- so every header fact is pinned
// through it directly: claimant, payload offset, and legacy ordinal all come
// from one parse and are asserted together.

test "ext header: a name-stamped blob round-trips claimant and payload" {
    const name = "minimize";
    const body = [_]u8{ 0x5A, 1, 2, 3, 4 };
    const header_len = 2 + name.len;
    // The exact shape the save path writes.
    var blob: [header_len + body.len]u8 = undefined;
    blob[0] = handoff.ext_format_version;
    blob[1] = @as(u8, @intCast(name.len));
    @memcpy(blob[2..header_len], name);
    @memcpy(blob[header_len..], &body);

    const h = handoff.decodeExt(&blob);
    try testing.expectEqualStrings(name, h.claimed_name.?);
    // The payload starts right after the name: an off-by-one here would hand a
    // module a blob whose magic byte is the name's first byte, which is
    // exactly the silent non-claim the stamp was meant to avoid.
    try testing.expectEqualSlices(u8, &body, h.payload);
    try testing.expect(h.legacy_ordinal == null);
}

test "ext header: truncated, foreign, and unstamped blobs never slice out of bounds" {
    // Claims a 200-byte name in a 3-byte header.
    const lying = [_]u8{ handoff.ext_format_version, 200, 'x' };
    const h_lying = handoff.decodeExt(&lying);
    try testing.expectEqual(@as(?[]const u8, null), h_lying.claimed_name);
    try testing.expectEqualSlices(u8, &lying, h_lying.payload);
    // Too short to hold a version byte at all.
    const one = [_]u8{handoff.ext_format_version};
    try testing.expectEqualSlices(u8, &one, handoff.decodeExt(&one).payload);
    try testing.expectEqualSlices(u8, &[_]u8{}, handoff.decodeExt(&[_]u8{}).payload);
    // A future format we do not know: no header interpretation, and the
    // caller falls back to passing the bytes through whole.
    const future = [_]u8{ 99, 1, 2 };
    const h_fut = handoff.decodeExt(&future);
    try testing.expectEqualSlices(u8, &future, h_fut.payload);
    try testing.expectEqual(@as(?[]const u8, null), h_fut.claimed_name);
    try testing.expectEqual(@as(?usize, null), h_fut.legacy_ordinal);
}

test "ext header: a legacy ordinal-stamped blob still resolves" {
    // What the previous format wrote: [version=1][ordinal][payload].
    const legacy = [_]u8{ handoff.ext_format_version_ordinal, 2, 0x5A, 0xFF };
    const h_legacy = handoff.decodeExt(&legacy);
    try testing.expectEqual(@as(?usize, 2), h_legacy.legacy_ordinal);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x5A, 0xFF }, h_legacy.payload);
    try testing.expectEqual(@as(?[]const u8, null), h_legacy.claimed_name);
    // A name-stamped blob must NOT be read as a legacy ordinal: byte 1 is the
    // name LENGTH there, so conflating the two would send "minimize" to
    // registry slot 8. (An earlier draft of this test wrote 7 for a name that
    // is 8 bytes long, and the reader correctly returned "minimiz" -- the
    // length byte is authoritative, which is the property worth pinning.)
    const modern = [_]u8{ handoff.ext_format_version, 8, 'm', 'i', 'n', 'i', 'm', 'i', 'z', 'e', 0x5A };
    const h_modern = handoff.decodeExt(&modern);
    try testing.expect(h_modern.legacy_ordinal == null);
    try testing.expectEqualStrings("minimize", h_modern.claimed_name.?);
    try testing.expectEqualSlices(u8, &[_]u8{0x5A}, h_modern.payload);
}

test "decodeExt passes an unrecognized blob through whole" {
    // A foreign/truncated header has no interpretation, so the payload must be
    // the WHOLE blob -- this is the graceful degrade that lets an unclaimed or
    // future-format blob still reach the module scan.
    const future = [_]u8{ 99, 1, 2 };
    const h = handoff.decodeExt(&future);
    try testing.expectEqualSlices(u8, &future, h.payload);
    try testing.expectEqual(@as(?[]const u8, null), h.claimed_name);
    try testing.expectEqual(@as(?usize, null), h.legacy_ordinal);

    const lying = [_]u8{ handoff.ext_format_version, 200, 'x' };
    const h2 = handoff.decodeExt(&lying);
    try testing.expectEqualSlices(u8, &lying, h2.payload);
    try testing.expectEqual(@as(?[]const u8, null), h2.claimed_name);

    const empty = [_]u8{};
    try testing.expectEqualSlices(u8, &empty, handoff.decodeExt(&empty).payload);
}
