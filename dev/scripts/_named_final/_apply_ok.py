import pathlib, sys

p = pathlib.Path("/home/akai/eudaimonia/hana/src/test/engine/model_test.zig")
t = p.read_text(encoding="utf-8")

AMP = chr(38)   # &
DOT = chr(46)   # .
LBR = chr(123)  # {
RBR = chr(125)  # }
CM  = chr(44)   # ,
SP  = " "
LP  = chr(40)   # (
RP  = chr(41)   # )
M   = "m"

WIN = "unknown_win"
FAR = "far_position"
BLOB = "foreign_blob"
AMP_M = AMP + M

amp_win = AMP_M + CM + SP   # "&m, "
amp = AMP + SP               # "& "

def cnt(needle):
    return t.count(needle)

def must(needle, n):
    got = cnt(needle)
    if got != n:
        print("GUARD %d!=%d : %r" % (got, n, needle))
        sys.exit(2)

def rep(needle, repl, n=1):
    must(needle, n)
    return t.replace(needle, repl, n)

# magic ids 999 (body sites only):
t = rep("minimize.restore(&m, 999);", "minimize.restore(&m, " + WIN + ");")
t = rep("model.visibleOn(&m, 999, WSId.fromIndex(0)));",
        "model.visibleOn(&m, " + WIN + ", WSId.fromIndex(0)));")
t = rep("model.unregister(&m, 999);", "model.unregister(&m, " + WIN + ");")
t = rep("model.setFocus(&m, 999);", "model.setFocus(&m, " + WIN + ");")
t = rep("fullscreen.fullscreenWsOf(&m, 999)", "fullscreen.fullscreenWsOf(&m, " + WIN + ")")
t = rep("fullscreen.isFullscreenMode(&m, 999))",
        "fullscreen.isFullscreenMode(&m, " + WIN + "))")
t = rep("fullscreen.isFullscreenOnWs(&m, 999, WSId.fromIndex(0)));",
        "fullscreen.isFullscreenOnWs(&m, " + WIN + ", WSId.fromIndex(0)));")
t = rep("floating.honorConfigureRequest(&m, 999, .{ .x = 1 }),",
        "floating.honorConfigureRequest(&m, " + WIN + ", .{ .x = 1 }),")
t = rep("floating.setFloatingRect(&m, 999, new_r);",
        "floating.setFloatingRect(&m, " + WIN + ", new_r);")

# index/far/unknown-window roles:
t = rep("model.reorderTiled(&m, 1, 99);", "model.reorderTiled(&m, 1, " + FAR + ");")
t = rep("model.reorderTiled(&m, 42, 0);", "model.reorderTiled(&m, " + WIN + ", 0);")
t = rep("model.stepTiled(&m, 99, 1);", "model.stepTiled(&m, " + WIN + ", 1);")

# foreign blob &.{ 0x00, 1, 2 } (2 body sites; the const def line uses [_]u8{..} and stays)
blob_old = AMP + DOT + LBR + " 0x00, 1, 2 " + RBR
blob_new = AMP + BLOB
must(blob_old, 2)
t = t.replace(blob_old, blob_new, 2)

# sanity: no leftover magic 999 / 99 / 42-as-window remains unreferenced
if ("999" in t.replace("far_position", "").replace("unknown_win", "")):
    print("REMAINING 999")
    sys.exit(3)
if cnt(amp_win + "99,") > 0 or cnt(amp_win + "42,") > 0:
    print("REMAINING win99/42")
    sys.exit(4)

p.write_text(t, encoding="utf-8")
print("APPLIED OK bytes=%d" % len(t))
