# S12 — client-bw: a client-set border width is recorded and survives retiles
# (BC05). Uses tools/setbw.c (compiled on demand) which drives the
# ConfigureRequest BW path.
spawn_client A
spawn_client B
dump tiled-baseline
wid=$(client_id A)   # A: first-spawned, tiled master
client_bw "$wid" 9 || { echo "S12: setbw tool unavailable" >&2; return 1; }
settle 300
dump after-client-bw     # honored ConfigureRequest: width 9 recorded
key super+w          # swap-master forces a retile sweep over both windows
settle 400
dump after-retile    # width 9 must survive on that window; no stale dedup skip
state_dump
