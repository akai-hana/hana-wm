import pathlib, sys

p = pathlib.Path("/home/akai/eudaimonia/hana/src/test/engine/model_test.zig")
lines = p.read_text().split("\n")
orig = list(lines)

AMP = chr(38)   # &
DOT = chr(46)   # .
LBR = chr(123)  # {
RBR = chr(125)  # }
AMP_BLOB = AMP + DOT + LBR + " 0x00, 1, 2 " + RBR   # &.{ 0x00, 1, 2 }

NEEDLE999 = "m, 999"
SUB999 = "m, " + "unknown_win"
BLOB_NEW = AMP + "foreign_blob"

def check(i1, i2, needle, sub, extra="", cnt=1):
    if not (1 <= i1 <= i2 <= len(lines)):
        print("BAD RANGE %d..%d" % (i1, i2)); sys.exit(1)
    n = 0
    for k in range(i1 - 1, i2):
        if needle in lines[k]:
            n += 1
            if extra and extra not in lines[k]:
                print("CTX MISS at %d" % (k + 1)); sys.exit(2)
            lines[k] = lines[k].replace(needle, sub, 1)
        elif extra and extra in lines[k]:
            print("EXPECT NEEDLE at %d" % (k + 1)); sys.exit(3)
    if n != cnt:
        print("COUNT at %d..%d got %d want %d" % (i1, i2, n, cnt)); sys.exit(4)

# --- 999 window-id sites -> unknown_win ---
check(228, 228, NEEDLE999, SUB999)
check(329, 329, NEEDLE999, SUB999)
check(524, 524, NEEDLE999, SUB999)
check(576, 576, NEEDLE999, SUB999, extra="honorConfigureRequest")
check(619, 619, NEEDLE999, SUB999, extra="setFocus")
check(945, 945, NEEDLE999, SUB999, extra="fullscreenWsOf")
check(996, 996, NEEDLE999, SUB999, extra="isFullscreenMode")
check(997, 997, NEEDLE999, SUB999, extra="isFullscreenOnWs")
check(1156, 1156, NEEDLE999, SUB999, extra="setFloatingRect")

# --- reorderTiled(&m, 1, 99): 99 is the far TILED INDEX -> far_position ---
check(422, 422, "m, 1, 99", "m, 1, " + "far_position", extra="reorderTiled")
# --- reorderTiled(&m, 42, 0): 42 is an unknown WINDOW -> unknown_win ---
check(432, 432, "m, 42, 0", "m, " + "unknown_win, 0", extra="reorderTiled")
# --- stepTiled(&m, 99, 1): 99 is an unknown WINDOW -> unknown_win ---
check(479, 479, "m, 99, 1", "m, " + "unknown_win, 1", extra="stepTiled")

# --- foreign blob literal &.{ 0x00, 1, 2 } -> &foreign_blob (minim + fullscr) ---
n = 0
for k in range(len(lines)):
    if AMP_BLOB in lines[k] and "deserializeWindow" in lines[k]:
        lines[k] = lines[k].replace(AMP_BLOB, BLOB_NEW, 1)
        n += 1
if n != 2:
    print("BLOB COUNT got %d want 2" % n); sys.exit(5)

p.write_text("\n".join(lines))
d = sum(1 for a, b in zip(orig, lines) if a != b)
print("APPLIED %d changed lines" % d)
