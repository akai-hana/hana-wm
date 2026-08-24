# S21 — hints-resize: a fixed-size client (min=max) must keep its hinted
# geometry across layouts, focus changes, and a fullscreen round-trip
# (additive yardstick, SW-9 / S14F10; exercises hint clamping in emitView).
spawn_client A --fixed --w 300 --h 200
spawn_client B
dump fixed-tiled     # A centered in its slot at 300x200 (hint-clamped)

key super+w          # swap-master / retile around the hinted window
settle 400
dump after-swap      # A still exactly 300x200

key super+f          # fullscreen ignores hints by design
settle 400
dump fs-ignores-hints # screen-size rect regardless of hints
state_dump

key super+f          # back out; hint clamp must reapply
settle 500
dump fs-exited       # A restored to 300x200 in its slot
state_dump
