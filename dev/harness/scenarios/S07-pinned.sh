# S07 - pinned: a pinned window stays visible across switches (BC16).
spawn_client A
spawn_client B
key super+p          # pin focused (newest) to every workspace
settle 300
dump ws1-pinned
key super+2
settle 400
dump ws2             # pinned window must be mapped here too
key super+1
settle 400
dump ws1-back
state_dump
