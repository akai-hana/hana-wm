import pathlib, sys

p = pathlib.Path("/home/akai/eudaimonia/hana/src/test/engine/model_test.zig")
data = p.read_text(encoding="utf-8")

AMP=chr(38)  # &
DOT=chr(46)  # .
LBR=chr(123) # {
RBR=chr(125) # }
CM =chr(44)  # ,
LP =chr(40)  # (
RP =chr(41)  # )
SCL=chr(59)  # ;
SP =" "
M  ="m"

WIN="unknown_win"
FAR="far_position"
BLOB="foreign_blob"

AMC = AMP+M+CM+SP                 # &m, 
ABLOB = AMP+BLOB                  # &foreign_blob
WSI = "WSId.fromIndex(0)"

def nABC():
    return AMC+"999"              # &m, 999

def n1_99():
    return "model.reorderTiled"+LP+AMC+"1"+CM+SP+"99"+RP+SCL       # reorderTiled(&m, 1, 99);
def n42_0():
    return "model.reorderTiled"+LP+AMC+"42"+CM+SP+"0"+RP+SCL       # reorderTiled(&m, 42, 0);
def n99_1():
    return "model.stepTiled"+LP+AMC+"99"+CM+SP+"1"+RP+SCL          # stepTiled(&m, 99, 1);
def nhonor():
    return "floating.honorConfigureRequest"+LP+AMC+"999"+CM        # honorConfigureRequest(&m, 999,
def nsetFocus():
    return "model.setFocus"+LP+AMC+"999"+RP+SCL
def nfws():
    return "fullscreen.fullscreenWsOf"+LP+AMC+"999"+RP+RP          # )); ends
def nifm():
    return "fullscreen.isFullscreenMode"+LP+AMC+"999"+RP+RP
def nifon():
    return "fullscreen.isFullscreenOnWs"+LP+AMC+"999"+CM
def nsfr():
    return "floating.setFloatingRect"+LP+AMC+"999"+CM
def blobold():
    return AMP+DOT+LBR+SP+"0x00"+CM+SP+"1"+CM+SP+"2"+SP+RBR        # &.{ 0x00, 1, 2 }

def guard1(k):
    c=data.count(k)
    if c!=1:
        print("GUARD %s count=%d want 1" % (k,c)); sys.exit(3)

def one(old,new,tag):
    guard1(old)
    return data.replace(old,new,1)

def swapSite(old,new,tag):
    global data
    guard1(old)
    data=data.replace(old,new,1)
    print("OK "+tag)

seg=AMC+WIN  # &m, unknown_win

# window-id 999 -> unknown_win (9 body sites)
swapSite("minimize.restore"+LP+AMC+"999"+RP+SCL, "minimize.restore"+LP+seg+RP+SCL,"restore999")
swapSite("model.visibleOn"+LP+AMC+"999"+CM,  "model.visibleOn"+LP+seg+CM,  "visible999")
swapSite("model.unregister"+LP+AMC+"999"+RP+SCL,"model.unregister"+LP+seg+RP+SCL,"unreg999")
swapSite(nhonor,"floating.honorConfigureRequest"+LP+seg+CM,"honor999")
swapSite(nsetFocus,"model.setFocus"+LP+seg+RP+SCL,"focus999")
swapSite(nfws,  "fullscreen.fullscreenWsOf"+LP+seg+RP+RP,"fws999")
swapSite(nifm,  "fullscreen.isFullscreenMode"+LP+seg+RP+RP,"ifm999")
swapSite(nifon, "fullscreen.isFullscreenOnWs"+LP+seg+CM,"ifon999")
swapSite(nsfr,  "floating.setFloatingRect"+LP+seg+CM,"sfr999")

# 99 as usize position (far_position) in reorderTiled(&m, 1, 99)
swapSite(n1_99, "model.reorderTiled"+LP+AMC+"1"+CM+SP+FAR+RP+SCL,"reorderFar99")

# 42 as unknown window id -> unknown_win  (reorderTiled(&m, 42, 0))
swapSite(n42_0, "model.reorderTiled"+LP+seg+CM+SP+"0"+RP+SCL,"reorder42win")

# 99 as unknown window id -> unknown_win  (stepTiled(&m, 99, 1))
swapSite(n99_1, "model.stepTiled"+LP+seg+CM+SP+"1"+RP+SCL,"step99win")

# foreign blob (&.{ 0x00, 1, 2 }) -> &foreign_blob (2 sites)
c=data.count(blobold())
if c!=2:
    print("GUARD blob count=%d want 2" % c); sys.exit(3)
data=data.replace(blobold(), ABLOB)
print("OK blobx2")

p.write_text(data, encoding="utf-8")
print("APPLIED all named constants")
