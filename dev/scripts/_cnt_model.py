import io

p = "/home/akai/eudaimonia/hana/src/test/engine/model_test.zig"
s = io.open(p, encoding="utf-8").read()

cands = [
    # window-id 999 sentinel
    r"minimize.restore(&m, 999);",
    r"visibleOn(&m, 999, WSId.fromIndex(0))",
    r"model.reorderTiled(&m, 1, 99);",
    r"model.reorderTiled(&m, 42, 0);",
    r"model.stepTiled(&m, 99, 1);",
    r"model.unregister(&m, 999);",
    r"honorConfigureRequest(&m, 999,",
    r"model.setFocus(&m, 999);",
    r"fullscreenWsOf(&m, 999)",
    r"fullscreen.isFullscreenMode(&m, 999)",
    r"fullscreen.isFullscreenOnWs(&m, 999, WSId.fromIndex(0))",
    r"floating.setFloatingRect(&m, 999, new_r);",
    # foreign blob literal
    r"&.{ 0x00, 1, 2 }",
    # store absent key
    r"m.store.remove(77)",
    # viewport probe value (should NOT change)
    r"params.viewport_offset = 42;",
    r".viewport_offset);",
]
for c in cands:
    print(f"{s.count(c):3d}  {c}")
