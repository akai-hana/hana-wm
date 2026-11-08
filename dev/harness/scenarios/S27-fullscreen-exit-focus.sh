# S27 - fullscreen exit focus: leaving fullscreen must not hand focus to a
# sibling that the reflow restores under the stationary pointer.
#
# Regression gate: the exit reconcile moves parked siblings back under the
# cursor, generating synthetic EnterNotify crossings. Focus-follows-mouse used
# to adopt them, stealing focus from the window that just left fullscreen.
spawn_client A
spawn_client B
wait_windows 2 || return 1

# Park the pointer away from the tiling area and let spawn focus settle.
DISPLAY="$HW_DISPLAY" xdotool mousemove 1270 780
wait_focused B || return 1

# Fullscreen B (the newest/focused window); it covers the whole screen.
key super+f
settle 300

# Park the pointer over the master slot's center: after the exit reflow A
# moves back under it, which is exactly the synthetic crossing that must be
# ignored.
DISPLAY="$HW_DISPLAY" xdotool mousemove --sync 315 380
settle 150
wait_focused B || return 1

# Exit fullscreen, leaving the pointer stationary over A's restored slot.
key super+f
settle 400
state_dump
focused_final B || return 1
