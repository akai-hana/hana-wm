# S09 - tag-move: moving the active window refocuses atomically, no hole (BC18).
spawn_client A
spawn_client B
spawn_client C
key super+shift+2    # move focused to ws2; focus falls back on ws1 immediately
settle 100           # small: catch the layout mid-transition if it has a hole
dump right-after
settle 400
dump settled
state_dump
