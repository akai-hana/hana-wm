import pathlib, sys

AF = "/home/akai/eudaimonia/hana/src/test/engine/model_test.zig"
lines = pathlib.Path(AF).read_text(encoding="utf-8").split("\n")

WIN = "unknown_win"
FAR = "far_position"

sites999 = [228, 329, 524, 576, 619, 945, 996, 997, 1156]
site99A  = 422      # reorderTiled(&m, 1, 99) -> 99 is far index -> far_position
site99B  = 479      # stepTiled(&m, 99, 1)  -> 99 is unknown window id -> unknown_win
site42   = 432      # reorderTiled(&m, 42, 0) -> 42 is unknown window id -> unknown_win

# guard: every replacement token must be used on exactly the intended occurrence
newline = list(lines)
for ln in sites999:
    c = lines[ln - 1].count("999")
    if c != 1:
        print("GUARD '999' line %d count=%d" % (ln, c))
        sys.exit(3)
    newline[ln - 1] = lines[ln - 1].replace("999", WIN, 1)

for ln in [site99A, site99B]:
    c = lines[ln - 1].count("99")
    if c != 1:
        print("GUARD '99' line %d count=%d" % (ln, c))
        sys.exit(3)

cA = lines[site99A - 1].count("42")
cB = lines[site42 - 1].count("42")
if cA != 0 or cB != 1:
    print("GUARD '42' mismatch %d/%d" % (cA, cB))
    sys.exit(3)

# apply far_position on reorder index, unknown_win on windows
newline[site99A - 1] = lines[site99A - 1].replace("99", FAR, 1)
newline[site99B - 1] = lines[site99B - 1].replace("99", WIN, 1)
newline[site42 - 1]  = lines[site42 - 1].replace("42", WIN, 1)

out = "\n".join(newline) + ("\n" if lines else "")
pathlib.Path(AF).write_text(out, encoding="utf-8")
print("WROTE 12 named-const sites (9x999, 99->far_position, 99->unknown_win, 42->unknown_win)")