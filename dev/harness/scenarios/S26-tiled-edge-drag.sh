# S26 - tiled edge-drag (D26): a Super+Button1 press on the master's right
# boundary adjusts primary_width in place -- both windows stay tiled --
# while a CENTER press with the same button still detaches to floating.
# Geometry at 1280x800 minus the 20px bottom bar: A=master 620x756+8+8,
# B=stack 620x756+644+8 (frame gap 16), truth right edge of A at x=628.
spawn_client A
spawn_client B
settle 300
dump initial
# Edge grab 2px inside A's right edge: within the 8px band, on A's content.
DISPLAY="$HW_DISPLAY" xdotool mousemove --sync 626 380
settle 100
DISPLAY="$HW_DISPLAY" xdotool keydown super
DISPLAY="$HW_DISPLAY" xdotool mousedown 1
for pos in '680 380' '730 380' '760 380'; do
	DISPLAY="$HW_DISPLAY" xdotool mousemove --sync $pos
	settle 60
done
settle 150           # let the last split commit land before release
DISPLAY="$HW_DISPLAY" xdotool mouseup 1
DISPLAY="$HW_DISPLAY" xdotool keyup super
settle 500
dump split           # A widened, B narrowed -- both still tiled
state_dump
# Center grab on the widened master: no split behind it -> float as ever.
DISPLAY="$HW_DISPLAY" xdotool mousemove --sync 400 380
settle 100
DISPLAY="$HW_DISPLAY" xdotool keydown super
DISPLAY="$HW_DISPLAY" xdotool mousedown 1
for pos in '460 400' '530 440'; do
	DISPLAY="$HW_DISPLAY" xdotool mousemove --sync $pos
	settle 60
done
settle 150
DISPLAY="$HW_DISPLAY" xdotool mouseup 1
DISPLAY="$HW_DISPLAY" xdotool keyup super
settle 500
dump floated
state_dump
