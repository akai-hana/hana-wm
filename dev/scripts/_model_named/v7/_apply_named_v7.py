import pathlib, sys

p = pathlib.Path("/home/akai/eudaimonia/hana/src/test/engine/model_test.zig")
lines = p.read_text(encoding="utf-8").split("\n")

AMP = chr(38)   # &
DOT = chr(46)   # .
LBR = chr(123)  # {
RBR = chr(125)  # }
CM  = chr(44)   # ,
SP  = " "
M   = "m"

WIN  = "unknown_win"   # 999
FAR  = "far_position"  # 99
BLOB = "foreign_blob"  # [_]u8{ 0x00, 1, 2 }

AM   = AMP + M                       # &m
AMC  = AM + CM + SP                  # &m, 
ABLOB= AMP + BLOB                    # &foreign_blob
_SPAC= chr(124)                       # not used

# needle for foreign blob literal, assembled via chr so no fragile bytes in source:
blob_needle = AMP + DOT + LBR + " 0x00, 1, 2 " + RBR        # &.{ 0x00, 1, 2 }
blob_repl   = ABLOB                                          # &foreign_blob

def must(line_idx, needle, repl, expect=1):
    target = lines[line_idx]
    got = target.count(needle)
    if got != expect:
        print("GUARD line %d for %r got %d want %d -> %r" % (line_idx + 1, target[:40], got, expect, target))
        sys.exit(3)
    lines[line_idx] = target.replace(needle, repl, 1)

# ---- 999 window-id sites (window arg, -> WIN) ----
must(227, "restore(" + AM + CM + SP + "999);", "restore(" + AM + CM + SP + WIN + ");")
must(328, "visibleOn(" + AM + CM + SP + "999,", "visibleOn(" + AM + CM + SP + WIN + ",")
must(523, "unregister(" + AM + CM + SP + "999);", "unregister(" + AM + CM + SP + WIN + ");")
must(575, "honorConfigureRequest(" + AM + CM + SP + "999,", "honorConfigureRequest(" + AM + CM + SP + WIN + ",")
must(618, "setFocus(" + AM + CM + SP + "999);", "setFocus(" + AM + CM + SP + WIN + ");")
must(944, "fullscreenWsOf(" + AM + CM + SP + "999)", "fullscreenWsOf(" + AM + CM + SP + WIN + ")")
must(995, "isFullscreenMode(" + AM + CM + SP + "999))", "isFullscreenMode(" + AM + CM + SP + WIN + "))")
must(996, "isFullscreenOnWs(" + AM + CM + SP + "999,", "isFullscreenOnWs(" + AM + CM + SP + WIN + ",")
must(1155, "setFloatingRect(" + AM + CM + SP + "999,", "setFloatingRect(" + AM + CM + SP + WIN + ",")

# ---- reorderTiled(&m, 1, 99): 99 is usize far_position ----
must(421, "model.reorderTiled(" + AM + CM + SP + "1," + SP + "99);",
        "model.reorderTiled(" + AM + CM + SP + "1," + SP + FAR + ");")

# ---- reorderTiled(&m, 42, 0): 42 is unknown window -> WIN ----
must(431, "model.reorderTiled(" + AM + CM + SP + "42," + SP + "0);",
        "model.reorderTiled(" + AM + CM + SP + WIN + "," + SP + "0);")

# ---- stepTiled(&m, 99, 1): 99 is unknown window -> WIN ----
must(478, "model.stepTiled(" + AM + CM + SP + "99," + SP + "1);",
        "model.stepTiled(" + AM + CM + SP + WIN + "," + SP + "1);")

# ---- foreign blob literal (2 sites: minimize L1214, fullscreen L1245) ----
nb = 0
for i in range(len(lines)):
    if blob_needle in lines[i]:
        lines[i] = lines[i].replace(blob_needle, blob_repl, 1)
        nb += 1
if nb != 2:
    print("BLOB sites got %d want 2" % nb)
    sys.exit(4)

p.write_text("\n".join(lines) + "\n", encoding="utf-8")
print("APPLIED named constants: 999->unknown_win, 99(idx)->far_position, 42/99(win)->unknown_win, blob->&foreign_blob")
