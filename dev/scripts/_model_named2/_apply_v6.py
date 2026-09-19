import sys, pathlib

p = pathlib.Path("/home/akai/eudaimonia/hana/src/test/engine/model_test.zig")
lines = p.read_text().split("\n")

# ---------- chr() assembly so no fragile &.{ 0x00... char ever appears ---
amp = chr(38)          # &
dot = chr(46)          # .
lbr = chr(123)         # {
rbr = chr(125)         # }
amp_m = amp + "m"      # &m
sp = " "
com = ", "
openp = "("
closep = ")"
semi = ";"

# Sentinel const names already defined in this file at L39/41/44:
WIN = "unknown_win"      # = 999
FAR = "far_position"     # = 99
BLOB = "foreign_blob"    # = [_]u8{ 0x00, 1, 2 }

def mk999(inner):
    # needle text: ..., 999, ...  -> uses 999 only
    return inner.replace("999", "")

def sub(old_piece, new_piece, expect):
    n = 0
    for i, ln in enumerate(lines):
        if old_piece in ln:
            lines[i] = ln.replace(old_piece, new_piece, 1)
            n += 1
    if n != expect:
        print("EXPECT %d GOT %d -- %r" % (expect, n, old_piece))
        sys.exit(2)

# blob needle &.{ 0x00, 1, 2 }  ->  &foreign_blob   (2 sites: minimize 1215, fullscreen 1246)
blob_old = amp + dot + lbr + sp + "0x00," + sp + "1," + sp + "2" + sp + rbr
blob_new = amp + BLOB
n = 0
for i, ln in enumerate(lines):
    if blob_old in ln:
        lines[i] = ln.replace(blob_old, blob_new, 1)
        n += 1
if n != 2:
    print("BLOB EXPECT 2 GOT %d" % n)
    sys.exit(2)

# window-id 999 -> unknown_win. Exact current needles (each unique in file):
sub("minimize.restore(&m, 999);", "minimize.restore(&m, " + WIN + ");", 1)
sub("model.visibleOn(&m, 999,", "model.visibleOn(&m, " + WIN + ",", 1)
sub("model.unregister(&m, 999);", "model.unregister(&m, " + WIN + ");", 1)
sub("floating.honorConfigureRequest(&m, 999,", "floating.honorConfigureRequest(&m, " + WIN + ",", 1)
sub("model.setFocus(&m, 999);", "model.setFocus(&m, " + WIN + ");", 1)
sub("fullscreen.fullscreenWsOf(&m, 999)", "fullscreen.fullscreenWsOf(&m, " + WIN + ")", 1)
sub("fullscreen.isFullscreenMode(&m, 999)", "fullscreen.isFullscreenMode(&m, " + WIN + ")", 1)
sub("fullscreen.isFullscreenOnWs(&m, 999,", "fullscreen.isFullscreenOnWs(&m, " + WIN + ",", 1)
sub("floating.setFloatingRect(&m, 999,", "floating.setFloatingRect(&m, " + WIN + ",", 1)

# 99-as-far-index (usize) -> far_position ; 42-as-window -> unknown_win ; 99-as-window -> unknown_win
sub("model.reorderTiled(&m, 1, 99);", "model.reorderTiled(&m, 1, " + FAR + ");", 1)
sub("model.reorderTiled(&m, 42, 0);", "model.reorderTiled(&m, " + WIN + ", 0);", 1)
sub("model.stepTiled(&m, 99, 1);", "model.stepTiled(&m, " + WIN + ", 1);", 1)

# --- helpers.zig does NOT exist; nothing to repair there (verified via ls) ---

p.write_text("\n".join(lines) + "\n", encoding="utf-8")
print("APPLY OK")

# ---- non-destructive python-side verification (untrusted needles, trusted count) ----
d = p.read_bytes()
res = {
    "blob_sites": d.count((amp + dot + lbr + sp + "0x00, 1, 2" + sp + rbr).encode()),
    "win_sites": d.count((amp + "m, " + "999").encode()),
    "idx99_sites": d.count((amp + "m, 1, 99").encode()),
}
