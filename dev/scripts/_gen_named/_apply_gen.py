import pathlib, sys

p = pathlib.Path("/home/akai/eudaimonia/hana/src/test/engine/model_test.zig")
lines = p.read_text(encoding="utf-8").split("\n")

AMP = chr(38)   # &
DOT = chr(46)   # .
LBR = chr(123)  # {
RBR = chr(125)  # }
CM  = chr(44)   # ,
SP  = " "
LP  = chr(40)   # (
RP  = chr(41)   # )
M   = "m"
CM_SP = CM + SP

WIN = "unknown_win"     # WindowId 999
FAR = "far_position"    # usize 99
BLOB = "foreign_blob"   # [_]u8{ 0x00, 1, 2 }

AMP_M    = AMP + M                      # &m
AMP_COM  = AMP_M + CM + SP              # &m, 
AMP_BLOB = AMP + BLOB                   # &foreign_blob
_WSI = "WSId.fromIndex(0)"
_equal_qt = "try testing.expectEqual("

def guard(entry):
    data = entry
    pass

# Sites built as (must_match_line_OF_current_file, replacement_line). Indices 1-based.
# Each site guarded: current line MUST equal needle (byte-exact). Off by one -> bail, no write.

S = []  # (idx, needle, repl)

def add(idx, repl):
    S.append((idx, None, repl))

# ---------- window-id 999 sites ----------
amp_999 = AMP_M + CM + SP + "999"
def win_line(*parts):
    return amp_999.join(parts)

# 1) L228  minimize.restore(&m, 999);
add(228, "minimize.restore(" + AMP_M + CM + SP + WIN + ");")
# 2) L329  visibleOn(&m, 999, WSId.fromIndex(0))
add(329, "    try testing.expect(!model.visibleOn(" + AMP_M + CM + SP + WIN +
    CM + SP + _WSI + "));")
# 3) L524  unregister(&m, 999);
add(524, "    model.unregister(" + AMP_M + CM + SP + WIN + ");")
# 4) L576  honorConfigureRequest(&m, 999, .{ .x = 1 }),
hon_cfg = "        floating.honorConfigureRequest(" + AMP_M + CM + SP + WIN + \
    CM + SP + DOT + LBR + SP + DOT + "x = 1 " + RBR + CM
add(576, hon_cfg)
# 5) L619  setFocus(&m, 999);
add(619, "    model.setFocus(" + AMP_M + CM + SP + WIN + ");")
# 6) L945  fullscreenWsOf(&m, 999)  (unknown)
add(945, "    try testing.expectEqual(" + chr(64) + "as(?WSId, null), fullscreen" +
    DOT + "fullscreenWsOf(" + AMP_M + CM + SP + WIN + ")); // unknown")
# 7) L996  isFullscreenMode(&m, 999)  (unknown id)
add(996, "    try testing.expect(!fullscreen" + DOT + "isFullscreenMode(" +
    AMP_M + CM + SP + WIN + ")); // unknown id")
# 8) L997  isFullscreenOnWs(&m, 999, WSId.fromIndex(0))  (unknown id)
add(997, "    try testing.expect(!fullscreen" + DOT + "isFullscreenOnWs(" +
    AMP_M + CM + SP + WIN + CM + SP + _WSI + ")); // unknown id")
# 9) L1156 setFloatingRect(&m, 999, new_r);
add(1156, "    floating" + DOT + "setFloatingRect(" + AMP_M + CM + SP + WIN +
    CM + SP + "new_r);")

# ---------- index-99 far_position (KEEP value 99, name it) ----------
# 10) L422 reorderTiled(&m, 1, 99);  99 = target tiled index (usize)
add(422, "    model" + DOT + "reorderTiled(" + AMP_M + CM + SP + "1" + CM + SP +
    FAR + ");")

# ---------- window-id 42 (unknown) ----------
# 11) L432 reorderTiled(&m, 42, 0);  42 = unknown window id (floating probe)
add(432, "    model" + DOT + "reorderTiled(" + AMP_M + CM + SP + WIN + CM + SP + "0);")

# ---------- window-id 99 (stepTiled unknown window) ----------
# 12) L479 stepTiled(&m, 99, 1);  99 = unknown window id
add(479, "    model" + DOT + "stepTiled(" + AMP_M + CM + SP + WIN + CM + SP + "1);")

# ---------- foreign blob literal &.{ 0x00, 1, 2 } ----------
# 13) L1215 minimize.deserializeWindow(70, &.{ 0x00, 1, 2 }, @ptrCast(&m))
add(1215, "    try testing.expect(!minimize" + DOT + "deserializeWindow(" + "70" +
    CM + SP + AMP_BLOB + CM + SP + "@ptrCast(" + AMP_M + ")));")
# 14) L1246 fullscreen.deserializeWindow(80, &.{ 0x00, 1, 2 }, @ptrCast(&m))
add(1246, "    try testing.expect(!fullscreen" + DOT + "deserializeWindow(" + "80" +
    CM + SP + AMP_BLOB + CM + SP + "@ptrCast(" + AMP_M + ")));")

# fill needles from current file (authoritative), require EXACT line match
needles = {}
for idx, needle, repl in S:
    ln = lines[idx - 1] if idx - 1 < len(lines) else None
    needle = ln

changed = 0
for idx, needle, repl in S:
    if needle is None:
        print("SITE %d MISSING LINE" % idx)
        sys.exit(2)
    if not needle.endswith(repl):
        pass

# Simple approach: verify needle is uniquely present among all lines, then replace that line.
for idx, needle, repl in S:
    got = 0
    for k in range(len(lines)):
        if lines[k] == needle:
            got += 1
    if got != 1:
        print("GUARD site %d got %d" % (idx, got))
        sys.exit(3)

for idx, needle, repl in S:
    lines[idx - 1] = repl
    changed += 1

out = "\n".join(lines) + "\n"
p.write_text(out, encoding="utf-8")
print("APPLIED %d lines" % changed)
