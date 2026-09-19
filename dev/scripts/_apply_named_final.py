import pathlib, sys

p = pathlib.Path("/home/akai/eudaimonia/hana/src/test/engine/model_test.zig")
t = p.read_text(encoding="utf-8")
orig_len = len(t)

AMP = chr(38)   # &
DOT = chr(46)   # .
LBR = chr(123)  # {
RBR = chr(125)  # }
CM  = chr(44)   # ,
SP  = chr(32)   # space
M   = chr(109)  # m

WIN  = "unknown_win"      # WindowId = 999
FAR  = "far_position"     # usize = 99
BLOB = "foreign_blob"

AMP_M = AMP + M            # &m
COMMA_SP = CM + SP         # ", "

def sub_once(needle, repl, want_n, label):
    global t
    n = t.count(needle)
    if n != want_n:
        print("GUARD[%s] got %d want %d" % (label, n, want_n))
        sys.exit(2)
    t = t.replace(needle, repl, want_n)

# ---- window-id 999 (sentinel) -> unknown_win : replace &m, 999 everywhere in body ----
old999 = AMP_M + chr(44) + SP + "999"        # &m, 999
new999 = AMP_M + chr(44) + SP + WIN
# count sites: 228,329,524,576,619,945,996,997,1156  (each unique)
body999 = t.count(old999)
if body999 != 9:
    print("GUARD[999] got %d" % body999)
    sys.exit(2)
t = t.replace(old999, new999)

# viewport_offset probe value 42 (i32) - KEEP (587/599) ; but 42-as-WindowId at reorderTiled(&m, 42, 0) -> unknown_win
old42 = AMP_M + chr(44) + SP + "42" + chr(44) + SP + "0"
new42 = AMP_M + chr(44) + SP + WIN + chr(44) + SP + "0"
sub_once(old42, new42, 1, "reorder42win")

# far_position: reorderTiled(&m, 1, 99) : 99 is usize index -> far_position
old99idx = AMP_M + chr(44) + SP + "1" + chr(44) + SP + "99"
new99idx = AMP_M + chr(44) + SP + "1" + chr(44) + SP + FAR
sub_once(old99idx, new99idx, 1, "reorder99idx")

# stepTiled(&m, 99, 1) : 99 is WindowId (unknown win) -> unknown_win
old99win = AMP_M + chr(44) + SP + "99" + chr(44) + SP + "1"
new99win = AMP_M + chr(44) + SP + WIN + chr(44) + SP + "1"
sub_once(old99win, new99win, 1, "step99win")

# ---- foreign blob literal &.{ 0x00, 1, 2 } -> &foreign_blob (2 sites) ----
blob_old = AMP + DOT + LBR + " 0x00" + CM + SP + "1" + CM + SP + "2 " + RBR
blob_new = AMP + BLOB
sub_once(blob_old, blob_new, 2, "blob")

if len(t) == orig_len:
    print("NO CHANGE")
    sys.exit(3)

p.write_text(t, encoding="utf-8")
print("APPLIED bytes_now=%d" % len(t))
