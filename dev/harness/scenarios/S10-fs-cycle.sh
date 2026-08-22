# S10 — fs-cycle: enter/exit fullscreen restores border width AND pixel (BC14 gate).
spawn_client A
spawn_client B
dump tiled
key super+f          # fullscreen enter (newest focused)
settle 400
dump fullscreen      # screen-size rect, border width 0
state_dump
key super+f          # fullscreen exit
settle 400
dump exited          # borders back to config width/color — the hard regression gate
state_dump
