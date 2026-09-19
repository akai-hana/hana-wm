import pathlib, re, sys

p = pathlib.Path("/home/akai/eudaimonia/hana/src/test/engine/model_test.zig")

# Each entry: (old, new, expected_count)
# Magic window id 999 -> unknown_win
# Reorder target index 99 -> far_position
# Unknown-window-as-window 99 -> unknown_win (stepTiled/reorderTiled first arg)
# Foreign blob &.{ 0x00, 1, 2 } -> &foreign_blob
repl = [
    # blob sites (exactly the two deserialize calls)
    (b"minimize.deserializeWindow(70, &.{ 0x00, 1, 2 }, @ptrCast(&m)));",
     b"minimize.deserializeWindow(70, &foreign_blob, @ptrCast(&m)));", 1),
    (b"fullscreen.deserializeWindow(80, &.{ 0x00, 1, 2 }, @ptrCast(&m)));",
     b"fullscreen.deserializeWindow(80, &foreign_blob, @ptrCast(&m)));", 1),
    # window-id 999 sites (server always treats id as unknown window)
    (b"model.reorderTiled(&m, 42, 0);", b"model.reorderTiled(&m, unknown_win, 0);", 1),
    (b"model.stepTiled(&m, 99, 1);", b"model.stepTiled(&m, unknown_win, 1);", 1),
    (b"model.reorderTiled(&m, 1, 99);", b"model.reorderTiled(&m, 1, far_position);", 1),
    (b"model.setFocus(&m, 999);", b"model.setFocus(&m, unknown_win);", 1),
    (b"model.unregister(&m, 999);", b"model.unregister(&m, unknown_win);", 1),
    (b"minimize.restore(&m, 999);", b"minimize.restore(&m, unknown_win);", 1),
    (b"floating.honorConfigureRequest(&m, 999, .{ .x = 1 }),",
     b"floating.honorConfigureRequest(&m, unknown_win, .{ .x = 1 }),", 1),
    (b"floating.honorConfigureRequest(&m, 999, .{ .y = 1 }),",
     b"floating.honorConfigureRequest(&m, unknown_win, .{ .y = 1 }),", 1),
    (b"fullscreen.fullscreenWsOf(&m, 999)", b"fullscreen.fullscreenWsOf(&m, unknown_win)", 1),
    (b"fullscreen.isFullscreenMode(&m, 999)", b"fullscreen.isFullscreenMode(&m, unknown_win)", 1),
    (b"fullscreen.isFullscreenOnWs(&m, 999,", b"fullscreen.isFullscreenOnWs(&m, unknown_win,", 1),
    (b"fullscreen.fullscreenWsOf(&m, 999,", b"fullscreen.fullscreenWsOf(&m, unknown_win,", 1),
    (b"minimize.deserializeWindow(70, &.{ 0x00, 1, 2 },",
     b"minimize.deserializeWindow(70, &foreign_blob,", 0),
    (b"fullscreen.deserializeWindow(80, &.{ 0x00, 1, 2 },",
     b"fullscreen.deserializeWindow(80, &foreign_blob,", 0),
    (b"model.visibleOn(&m, 999,", b"model.visibleOn(&m, unknown_win,", 1),
]

data = p.read_bytes()

# Guard: verify expected counts before any mutation.
for old, new, exp in repl:
    c = data.count(old)
    if exp is not None and c != exp:
        print("EXPECT %d GOT %d for %r" % (exp, c, old))
        sys.exit(2)

# Apply first-pass pairs.
out = data
for old, new, exp in repl:
    if exp is None or exp == 0:
        continue
    c = out.count(old)
    if c != exp:
        print("APPLY GUARD %d != %d for %r" % (c, exp, old))
        sys.exit(3)
    out = out.replace(old, new)

# Second pass for the two blob sites done by scanning replaces already handled.
p.write_bytes(out)
print("APPLIED OK, wrote %d bytes" % len(out))
