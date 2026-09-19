import pathlib, sys

p = pathlib.Path("/home/akai/eudaimonia/hana/src/test/engine/model_test.zig")
data = p.read_text(encoding="utf-8")

# ---- symbols via chr (no reliance on authored punctuation) ----
AMP = chr(38)  # &
DOT = chr(46)  # .
LBR = chr(123) # {
RBR = chr(125) # }
CM  = chr(44)  # ,
SC  = chr(59)  # ;
LP  = chr(40)  # (
RP  = chr(41)  # )
EQ  = chr(61)  # =
SP  = " "
M   = "m"

WIN  = "unknown_win"
FAR  = "far_position"
BLOB = "foreign_blob"

AM      = AMP + M               # &m
AMC     = AM + CM + SP          # &m, 
ABLOB   = AMP + BLOB            # &foreign_blob
WSI     = "WSId.fromIndex(0)"
EQNULL  = EQ + "@as(?WSId, null)"

def one(n, r, tag):
    c = data.count(n)
    if c != 1:
        print("Guard %s count=%d want 1" % (tag, c))
        sys.exit(3)
    return data.replace(n, r, 1)

# replacing per-site, each needle guaranteed unique
repls = [
    ("minimize.restore(" + AMC + "999);",
     "minimize.restore(" + AMC + WIN + ");", "restore"),
    ("try testing.expect(!model.visibleOn(" + AMC + "999, " + WSI + "));",
     "try testing.expect(!model.visibleOn(" + AMC + WIN + ", " + WSI + "));", "visibleOn"),
    ("model.reorderTiled(" + AMC + "1, 99);",
     "model.reorderTiled(" + AMC + "1, " + FAR + ");", "reorderFar"),   # 99 = far index (usize)
    ("model.reorderTiled(" + AMC + "42, 0);",
     "model.reorderTiled(" + AMC + WIN + ", 0);", "reorder42"),          # 42 = unknown window
    ("model.stepTiled(" + AMC + "99, 1);",
     "model.stepTiled(" + AMC + WIN + ", 1);", "stepTiled"),             # 99 = unknown window
    ("model.unregister(" + AMC + "999);",
     "model.unregister(" + AMC + WIN + ");", "unregister"),
    ("floating.honorConfigureRequest(" + AMC + "999, .{ .x = 1 }),",
     "floating.honorConfigureRequest(" + AMC + WIN + ", .{ .x = 1 }),", "honor"),
    ("model.setFocus(" + AMC + "999);",
     "model.setFocus(" + AMC + WIN + ");", "setFocus"),
    ("fullscreen.fullscreenWsOf(" + AMC + "999));",
     "fullscreen.fullscreenWsOf(" + AMC + WIN + "));", "fullscreenWsOf"),
    ("fullscreen.isFullscreenMode(" + AMC + "999));",
     "fullscreen.isFullscreenMode(" + AMC + WIN + "));", "isFMode"),
    ("fullscreen.isFullscreenOnWs(" + AMC + "999, " + WSI + "));",
     "fullscreen.isFullscreenOnWs(" + AMC + WIN + ", " + WSI + "));", "isFOnWs"),
    ("floating.setFloatingRect(" + AMC + "999, new_r);",
     "floating.setFloatingRect(" + AMC + WIN + ", new_r);", "setFloatingRect"),
]

# blob literal: &.{ 0x00, 1, 2 } -> &foreign_blob (2 sites)
blob = AMP + DOT + LBR + " 0x00, 1, 2 " + RBR

for n, r, tag in repls:
    data = one(n, r, tag)

bc = data.count(blob)
if bc != 2:
    print("Guard blob count=%d want 2" % bc)
    sys.exit(3)
data = data.replace(blob, ABLOB)

p.write_text(data + ("\n" if not data.endswith("\n") else ""), encoding="utf-8")
print("APPLIED: 12 sites + 2 blob -> named constants")
