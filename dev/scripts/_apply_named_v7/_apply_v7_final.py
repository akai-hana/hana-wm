import pathlib, sys

p = pathlib.Path("/home/akai/eudaimonia/hana/src/test/engine/model_test.zig")
t0 = p.read_text(encoding="utf-8")

AMP = chr(38)   # &
DOT = chr(46)   # .
LBR = chr(123)  # {
RBR = chr(125)  # }
CM  = chr(44)   # ,
LP  = chr(40)   # (
RP  = chr(41)   # )
SP  = chr(32)   # space
M   = "m"
WSI0 = "WSId.fromIndex(0)"

WIN  = "unknown_win"     # = 999
FAR  = "far_position"    # = 99 (usize)
BLOB = "foreign_blob"

AM   = AMP + M                    # &m
AMCM = AM + CM + SP               # &m, 
AB   = AMP + BLOB                 # &foreign_blob

# --- blob literal needle: &.{ 0x00, 1, 2 } ---
blob_needle = AMP + DOT + LBR + " 0x00," + SP + "1," + SP + "2 " + RBR
blob_count = t0.count(blob_needle)
assert blob_count == 2, ("blob sites", blob_count)
t = t0.replace(blob_needle, AB)

def site(needle, repl, n=1):
    global t
    c = t.count(needle)
    assert c == n, ("site", needle, c, n)
    t = t.replace(needle, repl, n)

# window-id 999 -> unknown_win
site("minimize.restore(" + AMCM + "999);", "minimize.restore(" + AMCM + WIN + ");")
site("visibleOn(" + AMCM + "999," + SP + WSI0 + "));",
     "visibleOn(" + AMCM + WIN + "," + SP + WSI0 + "));")
site("unregister(" + AMCM + "999);", "unregister(" + AMCM + WIN + ");")
site("honorConfigureRequest(" + AMCM + "999," + SP + DOT + LBR + SP + DOT +
     "x = 1 " + RBR + "),",
     "honorConfigureRequest(" + AMCM + WIN + "," + SP + DOT + LBR + SP + DOT +
     "x = 1 " + RBR + "),"))
site("setFocus(" + AMCM + "999);", "setFocus(" + AMCM + WIN + ");")
site("fullscreenWsOf(" + AMCM + "999))", "fullscreenWsOf(" + AMCM + WIN + "))")
site("isFullscreenMode(" + AMCM + "999))", "isFullscreenMode(" + AMCM + WIN + "))")
site("isFullscreenOnWs(" + AMCM + "999," + SP + WSI0 + ")));",
     "isFullscreenOnWs(" + AMCM + WIN + "," + SP + WSI0 + ")));")
site("setFloatingRect(" + AMCM + "999," + SP + "new_r);",
     "setFloatingRect(" + AMCM + WIN + "," + SP + "new_r);")

# 99 as tiled INDEX (far position, usize)
site("reorderTiled(" + AMCM + "1," + SP + "99);",
     "reorderTiled(" + AMCM + "1," + SP + FAR + ");")
# 99 as unknown WINDOW (stepTiled)
site("stepTiled(" + AMCM + "99," + SP + "1);",
     "stepTiled(" + AMCM + WIN + "," + SP + "1);")
# 42 as unknown WINDOW (reorderTiled)
site("reorderTiled(" + AMCM + "42," + SP + "0);",
     "reorderTiled(" + AMCM + WIN + "," + SP + "0);")

p.write_text(t, encoding="utf-8")
print("APPLIED v7: all sites replaced, blob x2, now writing")
