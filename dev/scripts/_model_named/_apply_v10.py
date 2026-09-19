import pathlib

p = pathlib.Path('/home/akai/eudaimonia/hana/src/test/engine/model_test.zig')
L = p.read_text(encoding='utf-8').split('\n')

A=chr(38); D=chr(46); LB=chr(123); RB=chr(125); C=chr(44); Lp=chr(40); Rp=chr(41); Sp=' '; S2='  '

M='m'
WIN='unknown_win'
FAR='far_position'
BLOB='foreign_blob'

ac=A+M                 # &m
amc=ac+C+Sp            # &m, 
ab=A+BLOB              # &foreign_blob

def line(n): return L[n-1]
def setl(n,v): L[n-1]=v
def chk(n,v):
    if line(n)!=v:
        print('MISMATCH %d'%n); print(repr(line(n))); print(repr(v)); raise SystemExit(3)

# --- 999 as WindowId -> unknown_win (9 body sites) ---
chk(228, S2+'minimize.restore('+amc+'999);')
setl(228, S2+'minimize.restore('+amc+WIN+');')

chk(329, S2+'try testing.expect(!model.visibleOn('+amc+'999,'+Sp+'WSId.fromIndex(0)));')
setl(329, S2+'try testing.expect(!model.visibleOn('+amc+WIN+','+Sp+'WSId.fromIndex(0)));')

chk(524, S2+'model.unregister('+amc+'999);')
setl(524, S2+'model.unregister('+amc+WIN+');')

chk(576, Sp*8+'floating.honorConfigureRequest('+amc+'999,'+Sp+'.{ .x = 1 }),')
setl(576, Sp*8+'floating.honorConfigureRequest('+amc+WIN+','+Sp+'.{ .x = 1 }),')

chk(619, S2+'model.setFocus('+amc+'999);')
setl(619, S2+'model.setFocus('+amc+WIN+');')

chk(945, S2+'try testing.expectEqual('+A+S2+'@as(?'+D+'WSId, null), fullscreen.fullscreenWsOf('+amc+'999)));')
setl(945, S2+'try testing.expectEqual('+A+S2+'@as(?'+D+'WSId, null), fullscreen.fullscreenWsOf('+amc+WIN+')));')

chk(996, S2+'try testing.expect(!fullscreen.isFullscreenMode('+amc+'999)));')
setl(996, S2+'try testing.expect(!fullscreen.isFullscreenMode('+amc+WIN+')));')

chk(997, S2+'try testing.expect(!fullscreen.isFullscreenOnWs('+amc+'999,'+Sp+'WSId.fromIndex(0)));')
setl(997, S2+'try testing.expect(!fullscreen.isFullscreenOnWs('+amc+WIN+','+Sp+'WSId.fromIndex(0)));')

chk(1156, S2+'floating.setFloatingRect('+amc+'999,'+Sp+'new_r);')
setl(1156, S2+'floating.setFloatingRect('+amc+WIN+','+Sp+'new_r);')

# --- 99 as far position (usize index) -> far_position ---
chk(422, S2+'model.reorderTiled('+amc+'1,'+Sp+'99);')
setl(422, S2+'model.reorderTiled('+amc+'1,'+Sp+FAR+');')

# --- reorderTiled(&m, 42, 0): 42 window id -> unknown_win ---
chk(432, S2+'model.reorderTiled('+amc+'42,'+Sp+'0);')
setl(432, S2+'model.reorderTiled('+amc+WIN+','+Sp+'0);')

# --- stepTiled(&m, 99, 1): 99 window id -> unknown_win ---
chk(479, S2+'model.stepTiled('+amc+'99,'+Sp+'1);')
setl(479, S2+'model.stepTiled('+amc+WIN+','+Sp+'1);')

# --- foreign blob : &.{ 0x00, 1, 2 } (2 sites L1215, L1246) -> &foreign_blob ---
blob=A+D+LB+Sp+'0x00,'+Sp+'1,'+Sp+'2 '+RB
nb=0
for n in (1215, 1246):
    if line(n).count(blob)!=1:
        print('BLOB mismatch %d'%n); raise SystemExit(3)
    setl(n, line(n).replace(blob, ab, 1))
    nb+=1
if nb!=2:
    print('BLOB count %d'%nb); raise SystemExit(3)

p.write_text('\n'.join(L)+'\n', encoding='utf-8')
print('APPLIED: 9x999->unknown_win, 99->far_position, 42->unknown_win, 99(step)->unknown_win, blob->foreign_blob')
