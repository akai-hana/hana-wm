import io, sys

p = "/home/akai/eudaimonia/hana/src/test/engine/model_test.zig"
s = io.open(p, encoding="utf-8").read()

# (old, new, expected_count)
subs = [
    # unknown_win --- all 999-as-window-id sites
    ("minimize.restore(&m, 999);", "minimize.restore(&m, unknown_win);", 1),
    ("try testing.expect(!model.visibleOn(&m, 999, WSId.fromIndex(0)));",
     "try testing.expect(!model.visibleOn(&m, unknown_win, WSId.fromIndex(0)));", 1),
    ("model.unregister(&m, 999);", "model.unregister(&m, unknown_win);", 1),
    ("floating.honorConfigureRequest(&m, 999, .{ .x = 1 }),",
     "floating.honorConfigureRequest(&m, unknown_win, .{ .x = 1 }),", 1),
    ("model.setFocus(&m, 999);", "model.setFocus(&m, unknown_win);", 1),
    ("fullscreen.fullscreenWsOf(&m, 999));", "fullscreen.fullscreenWsOf(&m, unknown_win));", 1),
    ("try testing.expect(!fullscreen.isFullscreenMode(&m, 999));",
     "try testing.expect(!fullscreen.isFullscreenMode(&m, unknown_win));", 1),
    ("try testing.expect(!fullscreen.isFullscreenOnWs(&m, 999, WSId.fromIndex(0)));",
     "try testing.expect(!fullscreen.isFullscreenOnWs(&m, unknown_win, WSId.fromIndex(0)));", 1),
    ("floating.setFloatingRect(&m, 999, new_r);", "floating.setFloatingRect(&m, unknown_win, new_r);", 1),
    # far_position --- 99 as reorder target index (usize)
    ("model.reorderTiled(&m, 1, 99);", "model.reorderTiled(&m, 1, far_position);", 1),
    # unknown_win --- 42 & 99 as unknown window ids in reorder/step
    ("model.reorderTiled(&m, 42, 0);", "model.reorderTiled(&m, unknown_win, 0);", 1),
    ("model.stepTiled(&m, 99, 1);", "model.stepTiled(&m, unknown_win, 1);", 1),
    # foreign_blob --- inline magic blob literals
    ("&.{ 0x00, 1, 2 }", "&foreign_blob", 6),
]

for old, new, want in subs:
    n = s.count(old)
    if n != want:
        print("FAIL count {!r}: expected {} found {}".format(old, want, n))
        sys.exit(1)

for old, new, _ in subs:
    s = s.replace(old, new)

io.open(p, "w", encoding="utf-8").write(s)
print("all %d replacement groups applied cleanly" % len(subs))
