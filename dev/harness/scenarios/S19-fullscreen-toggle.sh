# S19 — fullscreen-toggle: golden-first gate for the ConfigureRequest
# decision paths around fullscreen (ND-14): deny+echo while a window is
# fullscreen, border-only and mixed-mask routing, then exit restores slots.
# Window ids are resolved BEFORE the fullscreen enter: the parked sibling
# leaves the --onlyvisible view.
spawn_client A
spawn_client B
awid=$(client_id A) || true
fwid=$(client_id B) || true
[ -n "$awid" ] && [ -n "$fwid" ] || { echo "S19: cannot resolve client windows" >&2; exit 1; }

key super+f          # fullscreen B (newest focused)
settle 400
dump fs-entered      # screen-size rect for B; A parked offscreen
state_dump

client_geom "$awid" 100 100 200 150 5 || { echo "S19: setgeom tool unavailable" >&2; exit 1; }
settle 300
dump req-while-fs    # request against the parked tiled sibling must not un-park it

client_bw "$fwid" 7 || { echo "S19: setbw tool unavailable" >&2; exit 1; }
settle 300
dump bw-while-fs     # border-only request vs fullscreen window: denied (bw stays 0)

key super+f          # exit fullscreen
settle 400
dump fs-exited       # borders restored to config width/color; slots back
state_dump
