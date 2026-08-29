# S11 - configure-honored: a floating client's requested rect persists across
# minimize/restore (BC03). xdotool windowsize issues XResizeWindow, which the
# WM sees as an honored ConfigureRequest while the window floats.
spawn_client A
spawn_client B
key super+s          # float focused (newest)
settle 300
wid=$(client_id B)   # B is the floated one
DISPLAY="$HW_DISPLAY" xdotool windowsize --sync "$wid" 500 400
settle 300
dump floated-resized
key super+t          # minimize the floating window
settle 300
dump minimized
key super+shift+t    # restore: same requested rect must come back
settle 400
dump restored        # 500x400 at the dragged position, not a retile rect
state_dump
