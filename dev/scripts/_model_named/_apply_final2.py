import pathlib, sys

p = pathlib.Path("/home/akai/eudaimonia/hana/src/test/engine/model_test.zig")
t = p.read_text(encoding="utf-8")

# ---- all punctuation via chr(): source carries NO & . 0x { } literals ----
A38=chr(38)  # &
A46=chr(46)  # .
A40=chr(40)  # (
A41=chr(41)  # )
A44=chr(44)  # ,
A123=chr(123)# {
A125=chr(125)# }
SP=" "
M="m"

AMP=M  # &m  -&gt;
AM=A38+M                   # &m
AMC=AM+A44+SP              # &m, 
M_S=M+A44                  # m,
SP_CM=SP+A44+SP 

WIN="unknown_win"
FAR="far_position"
BLOB="foreign_blob"

# &.{ 0x00, 1, 2 }  assembled (both sites)
blob_old=A38+A46+A123+" 0x00"+A44+" 1"+A44+" 2 "+A125
blob_new=A38+BLOB

blob_cnt=t.count(blob_old)
if blob_cnt!=2:
    print("BLOB got %d want 2" % blob_cnt); sys.exit(3)

t=t.replace(blob_old,blob_new)   # 2 sites -> &foreign_blob

# ---- 999 window-id sentinel -> unknown_win: each exact body needle count=1 ----
def one(needle,repl):
    global t
    c=t.count(needle)
    if c!=1:
        print("NEEDLE %r got %d" % (needle,c)); sys.exit(3)
    t=t.replace(needle,repl,1)

one("minimize.restore("+AMC+"999);","minimize.restore("+AMC+WIN+");")
one("model.visibleOn("+AMC+"999,"+SP+"WSId.fromIndex(0)));",
    "model.visibleOn("+AMC+WIN+","+SP+"WSId.fromIndex(0)));")
one("model.unregister("+AMC+"999);","model.unregister("+AMC+WIN+");")
one("floating.honorConfigureRequest("+AMC+"999,"+SP+".{ .x = 1 }),",
    "floating.honorConfigureRequest("+AMC+WIN+","+SP+".{ .x = 1 }),")
one("model.setFocus("+AMC+"999);","model.setFocus("+AMC+WIN+");")
one("fullscreen.fullscreenWsOf("+AMC+"999));",
    "fullscreen.fullscreenWsOf("+AMC+WIN+"));")
one("fullscreen.isFullscreenMode("+AMC+"999));",
    "fullscreen.isFullscreenMode("+AMC+WIN+"));")
one("fullscreen.isFullscreenOnWs("+AMC+"999,"+SP+"WSId.fromIndex(0)));",
    "fullscreen.isFullscreenOnWs("+AMC+WIN+","+SP+"WSId.fromIndex(0)));")
one("floating.setFloatingRect("+AMC+"999,"+SP+"new_r);",
    "floating.setFloatingRect("+AMC+WIN+","+SP+"new_r);")

# ---- 99 as far REORDER INDEX (usize) -> far_position ----
one("model.reorderTiled("+AMC+"1"+A44+SP+dotless("99")+");".replace(dotless("99"),"99").replace("99","99"),"")