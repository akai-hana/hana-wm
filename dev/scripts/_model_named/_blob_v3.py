import pathlib, sys

p = pathlib.Path("/home/akai/eudaimonia/hana/src/test/engine/model_test.zig")
t = p.read_text(encoding="utf-8")

AMP = chr(38)   # ampersand
DOT = chr(46)   # period
LBR = chr(123)  # left brace
RBR = chr(125)  # right brace
CM  = chr(44)   # comma
SP  = " "
Z0  = chr(48) + chr(120) + chr(48) + chr(48)   # 0x00
ONE = "1"
TWO = "2"

# needle: &.{ 0x00, 1, 2 }
needle = AMP + DOT + LBR + SP + Z0 + CM + SP + ONE + CM + SP + TWO + SP + RBR
# replacement: &foreign_blob
repl   = AMP + "foreign_blob"

cnt = t.count(needle)
if cnt != 2:
    print("BLOB needle count=%d want 2" % cnt)
    sys.exit(3)

t2 = t.replace(needle, repl)
p.write_text(t2, encoding="utf-8")
print("BLOB_OK count=%d applied" % cnt)
