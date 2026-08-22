# S03 — min-restore: minimize parks + refocuses; restore returns to same slot.
spawn_client A
spawn_client B
dump before-min
key super+t          # minimize focused (B)
settle 300
dump minimized       # B must appear parked at x=-30000; A must be focused
state_dump
key super+shift+t    # unminimize_lifo -> B back to its slot
settle 400
dump restored
state_dump
