# S20 — layout-storm: rapid layout cycling plus master-count extremes.
# Additive yardstick (SW-9 / S14F10): every kind transition must keep all
# windows mapped and the focused window unchanged; master count clamps at
# both bounds (ND-22 upper clamp, lower bound 1).
spawn_client A
spawn_client B
spawn_client C
dump three-tiled

key super+space      # toggle_layout forward
settle 300
key super+space
settle 300
key super+shift+space  # reverse direction mid-storm
settle 300
key super+space
settle 300
key super+space
settle 400
dump after-storm     # same three mapped; focus preserved
state_dump

key super+comma      # increase_master_count
settle 250
key super+comma
settle 250
key super+period     # decrease_master_count
settle 250
key super+period
settle 250
key super+period
settle 250
key super+period
settle 400
dump counts-clamped  # floor at 1 master after over-decrease
state_dump
