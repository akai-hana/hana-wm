# S16 — close-then-respawn: the model registry must not leak closed windows.
#
# Regression gate for fix P0-1 (actions.unmanage was never called; ghosts
# accumulated in the model store and shifted every later window's slot).
spawn_client A
spawn_client B
settle 300

key super+j          # focus a stack window (B)
state_dump

key super+shift+f    # close focused
settle 400
dump two

# Respawn AFTER closing: with a leaked entry the new client takes the wrong
# layout slot and the state dump reports phantom windows.
spawn_client C
wait_named C 1
settle 400
dump respawned

state_dump
