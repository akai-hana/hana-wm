import pathlib, sys

p = pathlib.Path("/home/akai/eudaimonia/hana/src/test/engine/model_test.zig")
t = p.read_text()

AMP = "&"
DOT = "."
WIN = "unknown_win"
FAR = "far_position"
BLOB = "foreign_blob"

def sub(needle, repl, expected, label):
    n = t.count(needle)
    if n != expected:
        print("GUARD %s: got %d want %d" % (label, n, expected))
        sys.exit(2)
    t = t.replace(needle, repl)
    return t

blob_old = AMP + DOT + "{ 0x00, 1, 2 }"
blob_new = AMP + BLOB

t = sub(blob_old, blob_new, 2, "blob")

sites_999 = [
    ("minimize.restore(&m, 999);", 1),
    ("model.visibleOn(&m, 999, WSId.fromIndex(0)));", 1),
    ("model.unregister(&m, 999);", 1),
    ("honorConfigureRequest(&m, 999, .{ .x = 1 }),", 1),
    ("model.setFocus(&m, 999);", 1),
    ("fullscreen.fullscreenWsOf(&m, 999)", 1),
    ("fullscreen.isFullscreenMode(&m, 999))", 1),
    ("fullscreen.isFullscreenOnWs(&m, 999, WSId.fromIndex(0)));", 1),
    ("floating.setFloatingRect(&m, 999, new_r);", 1),
]
for needle, exp in sites_999:
    t = sub(needle, needle.replace("999", WIN), exp, "999-" + needle)

t = sub("reorderTiled(&m, 1, 99);", "reorderTiled(&m, 1, " + FAR + ");", 1, "far-idx")
t = sub("reorderTiled(&m, 42, 0);", "reorderTiled(&m, " + WIN + ", 0);", 1, "42-win")
t = sub("stepTiled(&m, 99, 1);", "stepTiled(&m, " + WIN + ", 1);", 1, "step99-win")

p.write_text(t)
print("ALL_APPLIED clean")
