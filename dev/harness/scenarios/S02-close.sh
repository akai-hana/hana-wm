# S02 — close: closing the stack window relayouts without holes.
spawn_client A
spawn_client B
spawn_client C
dump three
key super+j          # focus cycles away from newest (master) into the stack
state_dump
key super+shift+f    # close focused (a stack window)
settle 400
dump two
key super+shift+f    # close again
settle 400
dump one
