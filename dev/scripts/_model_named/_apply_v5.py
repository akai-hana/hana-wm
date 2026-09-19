import pathlib, sys

p = pathlib.Path("/home/akai/eudaimonia/hana/src/test/engine/model_test.zig")
s = p.read_text()

# ---- blob needle assembled from chr() to avoid fragile literal ----
amp = chr(38)          # &
dot = chr(46)          # .
lbr = chr(123)         # {
rbr = chr(125)         # }
blob_old = amp + dot + lbr + " 0x00, 1, 2 " + rbr
blob_new = amp + "foreign_blob"

def must(marker, needle, repl, count=1):
    global s
    n = s.count(needle)
    if n != count:
        print("COUNT %r got %d want %d" % (marker, n, count))
        sys.exit(2)
    s = s.replace(needle, repl, count)

must("restore999", "minimize.restore(&m, 999);", "minimize.restore(&m, unknown_win);")
must("visibleOn999", "model.visibleOn(&m, 999, WSId.fromIndex(0)));",
     "model.visibleOn(&m, unknown_win, WSId.fromIndex(0)));")
must("fullscreenWsOf999", "fullscreen.fullscreenWsOf(&m, 999)); // unknown",
     "fullscreen.fullscreenWsOf(&m, unknown_win)); // unknown")
must("isFullscreenMode999", "fullscreen.isFullscreenMode(&m, 999)); // unknown id",
     "fullscreen.isFullscreenMode(&m, unknown_win)); // unknown id")
must("isFullscreenOnWs999", "fullscreen.isFullscreenOnWs(&m, 999, WSId.fromIndex(0))); // unknown id",
     "fullscreen.isFullscreenOnWs(&m, unknown_win, WSId.fromIndex(0))); // unknown id")

# honorConfigureRequest: replace 999 within any honor line (x and y variants)
hon = s.split(chr(10))
used = 0
for i, ln in enumerate(hon):
    if "honorConfigureRequest(&m, 999," in ln:
        hon[i] = ln.replace("&m, 999,", "&m, " + "unknown_win" + ",", 1)
        used += 1
if used < 1:
    print("no honor sites")
    sys.exit(3)
s = chr(10).join(hon)

must("reorderFar", "model.reorderTiled(&m, 1, 99);",
     "model.reorderTiled(&m, 1, far_position);")
must("reorderUnknown", "model.reorderTiled(&m, 42, 0);",
     "model.reorderTiled(&m, unknown_win, 0);")
must("stepTiledUnknown", "model.stepTiled(&m, 99, 1);",
     "model.stepTiled(&m, unknown_win, 1);")
must("unregister999", "model.unregister(&m, 999);", "model.unregister(&m, unknown_win);")
must("setFocus999", "model.setFocus(&m, 999);", "model.setFocus(&m, unknown_win);")
must("setFloatingRect999", "floating.setFloatingRect(&m, 999, new_r);",
     "floating.setFloatingRect(&m, unknown_win, new_r);")
must("blob", blob_old, blob_new, count=2)

p.write_text(s)
print("OK applied; honor_sites=%d" % used)
