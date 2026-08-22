# S18 — EWMH fullscreen: client-requested _NET_WM_STATE works end to end.
#
# Regression gate for fix P0-3 (the client-message path was gated on the
# empty legacy registry and silently dropped requests).
spawn_client A
spawn_client B
settle 300

_id=$(client_id B)
[ -n "$_id" ] || { echo "S18: cannot resolve client B" >&2; exit 1; }

ewmh_fs "$_id" add      # ADD → window fullscreens (screen rect, bw=0)
settle 450
dump fs-added

state_dump

ewmh_fs "$_id" remove   # REMOVE → exits fullscreen back into its slot
settle 450
dump fs-removed

state_dump
