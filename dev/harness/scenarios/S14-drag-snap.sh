# S14 - drag-snap: scripted Super+Button1 drag of a floating window with
# edge snapping and live updates (BC21).
spawn_client A
key super+s          # float it
settle 300
# Master rect center for 1280x800 minus bottom bar is around (315, 380).
DISPLAY="$HW_DISPLAY" xdotool mousemove --sync 315 380
settle 100
DISPLAY="$HW_DISPLAY" xdotool keydown super
DISPLAY="$HW_DISPLAY" xdotool mousedown 1
for pos in '400 380' '600 390' '900 400' '1150 405' '1262 410'; do
	DISPLAY="$HW_DISPLAY" xdotool mousemove --sync $pos
	settle 60
done
settle 150           # let the last motion tick land before release
DISPLAY="$HW_DISPLAY" xdotool mouseup 1
DISPLAY="$HW_DISPLAY" xdotool keyup super
settle 500
dump dragged         # window parked near the right edge / snapped
state_dump
