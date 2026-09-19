import pathlib, sys

p = pathlib.Path("/home/akai/eudaimonia/hana/src/test/engine/model_test.zig")
t = p.read_text(encoding="utf-8")
lines = t.split("\n")

AMP = chr(38)   # &
DOT = chr(46)   # .
LBR = chr(123)  # {
RBR = chr(125)  # }
LP  = chr(40)   # (
RP  = chr(41)   # )
CM  = chr(44)   # ,
SP  = " "
EM  = ""

WIN  = "unknown_win"    # 999
FAR  = "far_position"   # 99  (usize)
BLOB = "foreign_blob"   # [_]u8{ 0x00, 1, 2 }

def count(needle):
    return sum(1 for ln in lines if needle in ln)

def require(needle, n):
    c = count(needle)
    if c != n:
        print("GUARD %d!=%d for %r" % (c, n, needle))
        sys.exit(2)

def repl(needle, new, n=1):
    require(needle, n)
    for i, ln in enumerate(lines):
        if needle in ln:
            lines[i] = ln.replace(needle, new, 1)

# ---- window-id 999 -> unknown_win (body sites only; const def at L39 stays) ----
R = AMP + "m, " + "999"       # &.m, 999  (the 999 is a WindowId to Replaces)
W = AMP + "m, " + WIN

sites_999 = [
    ("restore(&m, 999);",                      "restore(&m, " + WIN + ");"),
    ("visibleOn(&m, 999," + " WSId.fromIndex(0)));",
                                               "visibleOn(&m, " + WIN + "," + " WSId.fromIndex(0)));"),
    ("unregister(&m, 999);",                   "unregister(&m, " + WIN + ");"),
    ("honorConfigureRequest(&m, 999,",         "honorConfigureRequest(&m, " + WIN + ","),
    ("setFocus(&m, 999);",                     "setFocus(&m, " + WIN + ");"),
    ("fullscreenWsOf(&m, 999))",               "fullscreenWsOf(&m, " + WIN + "))"),
    ("isFullscreenMode(&m, 999))",             "isFullscreenMode(&m, " + WIN + "))"),
    ("isFullscreenOnWs(&m, 999," + " WSId.fromIndex(0)));",
                                               "isFullscreenOnWs(&m, " + WIN + "," + " WSId.fromIndex(0)));"),
    ("setFloatingRect(&m, 999,",               "setFloatingRect(&m, " + WIN + ","),
]
for old, new in sites_999:
    repl(old, new)

# ---- tiled index 99 -> far_position (reorderTiled win=1 idx=99; stepTiled win=99 is a WindowId!) ----
# reorderTiled(&m, 1, 99): 99 = target tiled index (usize) -> far_position
repl("reorderTiled(&m, 1, 99);", "reorderTiled(&m, 1, " + FAR + ");")
# stepTiled(&m, 99, 1): 99 = window id (unknown Window) -> unknown_win
repl("stepTiled(&m, 99, 1);", "stepTiled(&m, " + WIN + ", 1);")
# reorderTiled(&m, 42, 0): 42 = window id (unknown Window) -> unknown_win
repl("reorderTiled(&m, 42, 0);", "reorderTiled(&m, " + WIN + ", 0);")

# ---- foreign blob literal -> &foreign_blob (2 body sites) ----
blob_old = AMP + DOT + LBR + " 0x00, 1, 2 " + RBR      # &.{ 0x00, 1, 2 }
blob_new = AMP + BLOB
require(blob_old, 2)
for i, ln in enumerate(lines):
    if blob_old in ln:
        lines[i] = ln.replace(blob_old, blob_new, 1)

p.write_text("\n".join(lines) + ("\n" if t.endswith("\n") else ""), encoding="utf-8")
print("APPLIED_ok")
