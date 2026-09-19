import pathlib, sys

p = pathlib.Path("/home/akai/eudaimonia/hana/src/test/engine/model_test.zig")
data = p.read_text(encoding="utf-8")

A=chr(38)  # &
D=chr(46)  # .
L=chr(123) # {
R=chr(125) # }
C=chr(44)  # ,
SP=" "
M="m"

WIN="unknown_win"
FAR="far_position"
BLOB="foreign_blob"
AB=A+BLOB

def am(): return A+M       # &m
def amc(): return am()+C+SP   # &m, 
def blobold(): return A+D+L+" 0x00"+C+" 1"+C+" 2 "+R
def blobnew(): return A+BLOB

def cnt(n): return data.count(n)

def chk(n,tag,want):
    c=cnt(n)
    if c!=want:
        print("GUARD %s=%d want %d"%(tag,c,want)); sys.exit(3)

def rep(n,r,tag):
    chk(n,tag,1)
    global data
    data=data.replace(n,r,1)

import pathlib, sys
def am(): return A+M
def amc(): return am()+C+SP
WIN="unknown_win"; FAR="far_position"; BLOB="foreign_blob"
def blobold(): return A+D+L+" 0x00"+C+" 1"+C+" 2 "+R
def rep(n,r,tag):
    global data
    c=data.count(n)
    if c!=1:
        print("GUARD %s=%d"%(tag,c)); sys.exit(3)
    data=data.replace(n,r,1)

rep("minimize.restore("+amc()+"999);","minimize.restore("+amc()+WIN+");","restore999")
rep("model.visibleOn("+amc()+"999,"+" SP WSId.fromIndex(0)));", "model.visibleOn("+amc()+WIN+","+SP+"WSId.fromIndex(0)));","vis999")
cmd=amc()
