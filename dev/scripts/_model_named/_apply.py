import re, sys, pathlib

root = pathlib.Path("/home/akai/eudaimonia/hana")
prob = root / "src/test/engine/model_test.zig"
hlp  = root / "src/test/engine/helpers.zig"

def get_data(p):
    return p.read_bytes()

def main():
    ed = {}
    n = 0
    data = get_data(prob)
    for old, cnt in ed.items():
        got = data.count(old)
        if old not in ():
            pass
    blob = b"&.{ 0x00, 1, 2 }"
    got_blob = data.count(blob)
    print("blob_count=%d" % got_blob)

    official = {
        b"minimize.restore(&m, 999);": 1,
        b"try testing.expect(!model.visibleOn(&m, 999, WSId.fromIndex(0)));": 1,
        b"model.reorderTiled(&m, 1, 99);": 1,
        b"model.reorderTiled(&m, 42, 0);": 1,
        b"model.stepTiled(&m, 99, 1);": 1,
        b"model.unregister(&m, 999);": 1,
        b"floating.honorConfigureRequest(&m, 999, .{ .x = 1 }),": 1,
        b"model.setFocus(&m, 999);": 1,
        b"try testing.expectEqual(@as(?WSId, null), fullscreen.fullscreenWsOf(&m, 999));": 1,
        b"try testing.expect(!fullscreen.isFullscreenMode(&m, 999));": 1,
        b"try testing.expect(!fullscreen.isFullscreenOnWs(&m, 999, WSId.fromIndex(0)));": 1,
        b"floating.setFloatingRect(&m, 999, new_r);": 1,
    }
    repl = {
        b"minimize.restore(&m, 999);": b"minimize.restore(&m, unknown_win);",
        b"try testing.expect(!model.visibleOn(&m, 999, WSId.fromIndex(0)));": b"try testing.expect(!model.visibleOn(&m, unknown_win, WSId.fromIndex(0)));",
        b"model.reorderTiled(&m, 1, 99);": b"model.reorderTiled(&m, 1, far_position);",
        b"model.reorderTiled(&m, 42, 0);": b"model.reorderTiled(&m, unknown_win, 0);",
        b"model.stepTiled(&m, 99, 1);": b"model.stepTiled(&m, unknown_win, 1);",
        b"model.unregister(&m, 999);": b"model.unregister(&m, unknown_win);",
        b"floating.honorConfigureRequest(&m, 999, .{ .x = 1 }),": b"floating.honorConfigureRequest(&m, unknown_win, .{ .x = 1 }),",
        b"model.setFocus(&m, 999);": b"model.setFocus(&m, unknown_win);",
        b"try testing.expectEqual(@as(?WSId, null), fullscreen.fullscreenWsOf(&m, 999));": b"try testing.expectEqual(@as(?WSId, null), fullscreen.fullscreenWsOf(&m, unknown_win));",
        b"try testing.expect(!fullscreen.isFullscreenMode(&m, 999));": b"try testing.expect(!fullscreen.isFullscreenMode(&m, unknown_win));",
        b"try testing.expect(!fullscreen.isFullscreenOnWs(&m, 999, WSId.fromIndex(0)));": b"try testing.expect(!fullscreen.isFullscreenOnWs(&m, unknown_win, WSId.fromIndex(0)));",
        b"floating.setFloatingRect(&m, 999, new_r);": b"floating.setFloatingRect(&m, unknown_win, new_r);",
    }
    for old, exp in official.items():
        got = data.count(old)
        print("EXP %d GOT %d %r" % (exp, got, old))
        if got != exp:
            print("GUARD FAIL for %r" % old)
            sys.exit(2)

    nd = data
    for old, new in repl.items():
        nd = nd.replace(old, new, 1 hist)

    out = nd
    blob_new = b"&foreign_blob"
    sites = [b"minimize.deserializeWindow(70, ", b"fullscreen.deserializeWindow(80, "]
    # Replace &.{ ... } -> &foreign_blob only at the two blob sites (2 total).
    pieces = []
    idx = 0
    cnt = 0
    # find each sizeof pattern at the two known blobs
    tail1 = nd.find(b"minimize.deserializeWindow(70, ")
    tail2 = nd.find(b"fullscreen.deserializeWindow(80, ")
    def swap_site(buf, pos):
        p = buf.find(blob, pos)
        return p
    for pos in (tail1, tail2):
        p = swap_site(out if i == 0 else cur, pos)
    # simpler: operate on copy, replace blob occurrences that follow the two call markers
    # walk and replace each blob occurrence following these markers
    markers = [b"minimize.deserializeWindow(70, ", b"fullscreen.deserializeWindow(80, "]
    current = nd
    blob_count_used = 0
    for mk in markers:
        mkpos = current.find(mk)
        if mkpos < 0:
            print("MISSING MARKER %r" % mk)
            sys.exit(3)
        bpos = current.find(blob, mkpos)
        if bpos < 0:
            print("MISSING BLOB after %r" % mk)
            sys.exit(3)
        # make sure the blob is within the same call (limit window)
        current = current[:bpos] + blob_new + current[bpos + len(blob):]
        blob_count_used += 1
    if blob_count_used != 2:
        print("BLOB COUNT WRONG %d" % blob_count_used)
        sys.exit(4)
    out = current

    # helpers.zig fix
    hd = get_data(hlp)
    frag = b"const gap: u16 = std_env.margins"
    bad = b"const gap: u16 = std_env.margins.gap\xe4\xb8\x8b\xe6\x96\xb9\xe7\x9a\x84_margins\xe5\xa5\x87"
    hashes = ...
    print("helper_frag_got=%d" % hd.count(frag))
    print("helper_bad_got=%d" % hd.count(bad))
    if hd.count(bad) == 1:
        hd = hd.replace(bad, b"const gap: u16 = std_env.margins.gap;", 1)
    elif hd.count(frag) == 1:
        # generic repair of the mangled continuation
        pat = re.compile(rb"const gap: u16 = std_env\.margins\.gap[^\n]*;")
        def hre(m):
            return b"const gap: u16 = std_env.margins.gap;"
        nd2, k = pat.subn(hre, hd, count=1)
        if k == 1:
            hd = nd2
        else:
            print("HELPERS REPAIR SKIPPED (no clean match)")

    prob.write_bytes(out)
    hlp.write_bytes(hd)
    print("APPLIED %d model sites + helpers fix" % len(repl))
    print("helpers_gap_line_after:")
    for i, ln in enumerate(hlp.read_bytes().split(b"\n"), 1):
        if b"margins.gap" in ln and b"const gap" in ln:
            print("%d: %s" % (i, ln.decode("utf-8", "replace")))

main()
