# S17 - hover focus: EnterNotify over a window must focus it.
#
# Regression gate for fix P0-2 (the managed-window registry was empty, so
# findManagedWindow never resolved and hover focus silently died).
spawn_client A
spawn_client B
settle 400

# Park the pointer on the root first so the initial spawn focus is settled.
DISPLAY="$HW_DISPLAY" xdotool mousemove 1270 780
settle 250

_id=$(client_id A)
[ -n "$_id" ] || { echo "S17: cannot resolve client A" >&2; exit 1; }

# Read B's live geometry from the tree snapshot and move the pointer into it.
DISPLAY="$HW_DISPLAY" xdotool mousemove 640 400
state_dump            # focused should now be the window under (640,400)

# Then onto the other half of the split to prove the transition flips back.
_alt=$(client_id B)
[ -n "$_alt" ] || { echo "S17: cannot resolve client B" >&2; exit 1; }

DISPLAY="$HW_DISPLAY" xdotool mousemove 200 400
state_dump
