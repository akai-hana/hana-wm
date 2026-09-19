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

WIN  = "unknown_win"
FAR  = "far_position"
BLOB = "foreign_blob"

AM = AMP + M                 # &m
AMC = AM + CM + SP           # &m, 
ABLOB = AMP + BLOB           # &foreign_blob
at = chr(64) + "as("        # @as(

zigfmt_asserts = {
    # sites we REPLACE (line index 1-based -> new content)
}

def w(idx, newline):
    if idx < 1 or idx > len(lines):
        print("RANGE %d" % idx)
        sys.exit(2)
    lines[idx - 1] = newline

# 228: minimize.restore(&m, 999); -> unknown_win
w(228, "minimize.restore(" + AM + CM + SP + WIN + ");")
# 329: visibleOn(&m, 999, WSId.fromIndex(0)); -> unknown_win
w(329, "    try testing.expect(!model.visibleOn(" + AM + CM + SP + WIN +
    CM + SP + "WSId.fromIndex(0)));")
# 422: reorderTiled(&m, 1, 99); -> far_position (usize index 99)
w(422, "    model.reorderTiled(" + AM + CM + SP + "1" + CM + SP + FAR + ");")
# 432: reorderTiled(&m, 42, 0); -> unknown_win
w(432, "    model.reorderTiled(" + AM + CM + SP + WIN + CM + SP + "0);")
# 479: stepTiled(&m, 99, 1); -> unknown_win
w(479, "    model.stepTiled(" + AM + CM + SP + WIN + CM + SP + "1);")
# 524: unregister(&m, 999); -> unknown_win
w(524, "    model.unregister(" + AM + CM + SP + WIN + ");")
# 576: floating.honorConfigureRequest(&m, 999, .{ .x = 1 }), -> unknown_win
w(576, "        floating.honorConfigureRequest(" + AM + CM + SP + WIN +
    CM + SP + DOT + LBR + SP + DOT + "x = 1 " + RBR + CM)
# 619: model.setFocus(&m, 999); -> unknown_win
w(619, "    model.setFocus(" + AM + CM + SP + WIN + ");")
# 945: expectEqual(@as(?WSId, null), fullscreen.fullscreenWsOf(&m, 999)); -> unknown_win
w(945, "    try testing.expectEqual(" + at + "?WSId, null), fullscreen.fullscreenWsOf(" +
    AM + CM + SP + WIN + ")); // unknown")
# 996: expect(!fullscreen.isFullscreenMode(&m, 999)); -> unknown_win
w(996, "    try testing.expect(!fullscreen.isFullscreenMode(" + AM + CM + SP + WIN +
    ")); // unknown id")
# 997: expect(!fullscreen.isFullscreenOnWs(&m, 999, WSId.fromIndex(0))); -> unknown_win
w(997, "    try testing.expect(!fullscreen.isFullscreenOnWs(" + AM + CM + SP + WIN +
    CM + SP + "WSId.fromIndex(0))); // unknown id")
# 1156: floating.setFloatingRect(&m, 999, new_r); -> unknown_win
w(1156, "    floating.setFloatingRect(" + AM + CM + SP + WIN + CM + SP + "new_r);")
# 1215: minimize.deserializeWindow(70, &.{ 0x00, 1, 2 }, @ptrCast(&m))) -> &foreign_blob
w(1215, "    try testing.expect(!minimize.deserializeWindow(70, " + ABLOB +
    CM + SP + "@ptrCast(" + AM + ")));")
# 1246: fullscreen.deserializeWindow(80, &.{ 0x00, 1, 2 }, @ptrCast(&m))); -> &foreign_blob
w(1246, "    try testing.expect(!fullscreen.deserializeWindow(80, " + ABLOB +
    CM + SP + "@ptrCast(" + AM + ")));")

p.write_text("\n".join(lines) + "\n", encoding="utf-8")
print("APPLIED 14 named replacements")
