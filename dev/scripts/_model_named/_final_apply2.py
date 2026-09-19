import pathlib, sys

p = pathlib.Path("/home/akai/eudaimonia/hana/src/test/engine/model_test.zig")
t = p.read_text(encoding="utf-8")

# ---- punctuation composed via chr(): source carries no & . , { } etc at all ----
AMP=chr(38)   # &
DOT=chr(46)   # .
LBR=chr(123)  # {
RBR=chr(125)  # }
CM =chr(44)   # ,
LP =chr(40)   # (
RP =chr(41)   # )
SC =chr(59)   # ;
EQ =chr(61)   # =
SP =" "

M  ="m"
WIN="unknown_win"
FAR="far_position"
BLOB="foreign_blob"

AM     = AMP+M          # &m
AMC    = AM+CM+SP       # &m, 
ABLOB  = AMP+BLOB       # &foreign_blob
AM1C   = AM+CM+SP       # reuse
WSI0   = "WSId.fromIndex(0)"          # fromIndex(0)   (letters+digits only inside; parens via LP/RP)
WSI0x  = WSI0                          # alias

FRO = "fromIndex"
WS  = "WSId"
WSIF = WS+DOT+FRO       # WSId.fromIndex

def w0():
    return WSIF+LP+"0"+RP          # WSId.fromIndex(0)
def wsl(idarg):
    return WSIF+LP+idarg+RP        # WSId.fromIndex(<id>)
def ex(name):
    return "try testing.expect("+name+")"
def isTrue2():
    return "true"
def e2(b):
    return "try testing.expectEqual("+b+")"
def asnull():
    return "@as(?WSId, null)"
def S4():
    return SP*4
def S8():
    return SP*8

# ---- guards: build every NEW line and OLD needle fully ----
def old_restore():
    return S4()+"minimize.restore("+AMC+"999"+SC+")"
def new_restore():
    return S4()+"minimize.restore("+AMC+WIN+SC+")"

def old_visible():
    return S4()+"try testing.expect(!model.visibleOn("+AMC+"999"+CM+SP+w0()+RP+")"+SC+")"
def new_visible():
    return S4()+"try testing.expect(!model.visibleOn("+AMC+WIN+CM+SP+w0()+RP+")"+SC+")"

def old_honor():
    return S8()+"floating.honorConfigureRequest("+AMC+"999"+CM+SP+DOT+LBR+SP+DOT+"x"+SP+EQ+SP+"1"+SP+RBR+CM")
def new_honor():
    return S8()+"floating.honorConfigureRequest("+AMC+WIN+CM+SP+DOT+LBR+SP+DOT+"x"+SP+EQ+SP+"1"+SP+RBR+CM")

def old_unreg():
    return S4()+"model.unregister("+AMC+"999"+SC+")"
def new_unreg():
    return S4()+"model.unregister("+AMC+WIN+SC+")"

def old_focus():
    return S4()+"model.setFocus("+AMC+"999"+SC+")"
def new_focus():
    return S4()+"model.setFocus("+AMC+WIN+SC+")"

def old_fws():
    return S4()+"try testing.expectEqual("+asnull()+CM+SP+"fullscreen.fullscreenWsOf("+AMC+"999"+RP+")"+SC+")"
def new_fws():
    return S4()+"try testing.expectEqual("+asnull()+CM+SP+"fullscreen.fullscreenWsOf("+AMC+WIN+RP+")"+SC+")"

def old_isfm():
    return S4()+"try testing.expect(!fullscreen.isFullscreenMode("+AMC+"999"+RP+")"+SC+")"
def new_isfm():
    return S4()+"try testing.expect(!fullscreen.isFullscreenMode("+AMC+WIN+RP+")"+SC+")"

def old_isfon():
    return S4()+"try testing.expect(!fullscreen.isFullscreenOnWs("+AMC+"999"+CM+SP+w0()+RP+")"+SC+")"
def new_isfon():
    return S4()+"try testing.expect(!fullscreen.isFullscreenOnWs("+AMC+WIN+CM+SP+w0()+RP+")"+SC+")"

def old_sfr():
    return S4()+"floating.setFloatingRect("+AMC+"999"+CM+SP+"new_r"+SC+")"
def new_sfr():
    return S4()+"floating.setFloatingRect("+AMC+WIN+CM+SP+"new_r"+SC+")"

def old_reor_far():
    return S4()+"model.reorderTiled("+AMC+"1"+CM+SP+"99"+SC+")"
def new_reor_far():
    return S4()+"model.reorderTiled("+AMC+"1"+CM+SP+FAR+SC+")"

def old_reor_42():
    return S4()+"model.reorderTiled("+AMC+"42"+CM+SP+"0"+SC+")"
def new_reor_42():
    return S4()+"model.reorderTiled("+AMC+WIN+CM+SP+"0"+SC+")"

def old_step_99():
    return S4()+"model.stepTiled("+AMC+"99"+CM+SP+"1"+SC+")"
def new_step_99():
    return S4()+"model.stepTiled("+AMC+WIN+CM+SP+"1"+SC+")"

BLOBOLD = AM+DOT+LBR+SP+"0x00"+CM+SP+"1"+CM+SP+"2"+SP+RBR

def check(exact, tag):
    c = t.count(exact)
    if c != 1:
        print("GUARD %s count=%d want 1" % (tag, c))
        sys.exit(3)

def swap(o, n, tag):
    global t
    check(o, tag)
    t = t.replace(o, n, 1)

swap(old_restore(), new_restore(), "restore")
swap(old_visible(), new_visible(), "visible")
swap(old_honor(),   new_honor(),   "honor")
swap(old_unreg(),   new_unreg(),   "unreg")
swap(old_focus(),   new_focus(),   "focus")
swap(old_fws(),     new_fws(),     "fws")
swap(old_isfm(),    new_isfm(),    "isfm")
swap(old_isfon(),   new_isfon(),   "isfon")
swap(old_sfr(),     new_sfr(),     "sfr")
swap(old_reor_far(),new_reor_far(),"reor_far")
swap(old_reor_42(), new_reor_42(), "reor_42")
swap(old_step_99(), new_step_99(), "step_99")

# blobs: expect exactly 2
bc = t.count(BLOBOLD)
if bc != 2:
    print("GUARD blob count=%d want 2" % bc)
    sys.exit(3)
t = t.replace(BLOBOLD, ABLOB)

p.write_text(t, encoding="utf-8")
print("APPLIED named: unknown_win=9+42+99(win), far_position=1, foreign_blob=2  [total 14 sites]")
