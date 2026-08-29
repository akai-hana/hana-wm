# S06 - switch-basic: geometry stable across switch-away/switch-back.
spawn_client A
spawn_client B       # both on ws1
key super+shift+2    # move focused to ws2
settle 300
dump ws1-after-move
key super+2          # switch to ws2
settle 300
dump ws2
key super+1          # back to ws1
settle 400
dump ws1-back        # fast replay or full retile must yield same geometry
state_dump
