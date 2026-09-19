import pathlib, sys

FILE = "/home/akai/eudaimonia/hana/src/test/engine/model_test.zig"
p = pathlib.Path(FILE)
data = p.read_text(encoding="utf-8")

# ---- chr-assembled needles so THIS FILE contains no fragile literal bytes ----
AMP = chr(38)   # &
DOT = chr(46)   # .
LBR = chr(123)  # {
RBR = chr(125)  # }
CM  = chr(44)   # ,
LP  = chr(40)   # (
RP  = chr(41)   # )
SP  = " "
M   = "m"
D0  = "0x00"

AMP_M    = AMP + M                  # &m
AMP_CM   = AMP_M + CM + SP          # &m, 
CM_SP    = CM + SP
AMp      = AMP_M + CM + SP          # &m, 

WIN  = "unknown_win"     # 999
FAR  = "far_position"    # 99  (usize)
BLOB = "foreign_blob"    # [_]u8{ 0x00, 1, 2 }  (&foreign_blob)

AMP_BLOB = AMP + BLOB               # &foreign_blob

def needle_win_assign():
    return AMP_M + CM + SP + "999"   # &m, 999

def needle_far_99():
    return AMP_M + CM + SP + "99"    # &m, 99

def replacement_win():
    return AMP_M + CM + SP + WIN     # &m, unknown_win

def replacement_far():
    return AMP_M + CM + SP + FAR     # &m, far_position

# Foreign-blob literal: &.{ 0x00, 1, 2 }  assembled via chr.
d = DOT
L = LBR
R = RBR
blob_lit = AMP + d + L + " " + D0 + CM + " " + "1" + CM + " " + "2 " + R

def count(x):
    return data.count(x)

def check(label, needle, cnt):
    got = count(needle)
    if got != cnt:
        print("GUARD %s got %d want %d" % (label, got, cnt))
        sys.exit(2)

def swap(label, needle, repl, cnt=1):
    check(label, needle, cnt)
    global data
    data = data.replace(needle, repl, cnt)

# -------- window-id 999 -> unknown_win (9 body sites, all unique) --------
n999 = needle_win_assign()
r999 = replacement_win()
swap("minRestore",    n999 + ");",                        r999 + ");"   )  # not present; handled per-line below
