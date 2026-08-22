# S04 — min-from-fs: minimize while fullscreen, restore re-enters fullscreen
# with the saved rect (BC08).
spawn_client A
spawn_client B
key super+f          # fullscreen the focused (newest)
settle 400
dump fullscreen      # screen-size, bw=0; sibling parked
state_dump
key super+t          # minimize from fullscreen (saved_fs path)
settle 300
dump fs-minimized    # sibling comes back tiled
key super+shift+t    # restore -> straight back INTO fullscreen, saved rect
settle 500
dump fs-restored     # screen-size + EWMH fullscreen state set again
state_dump
