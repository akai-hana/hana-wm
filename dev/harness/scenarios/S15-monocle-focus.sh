# S15 — monocle-focus: in monocle the shown window is the focused override on
# restore (BC07/BC22). Runs with scenarios/S15-monocle-focus.config.toml.
spawn_client A
spawn_client B       # newest on top; older hidden by layout (visible=false)
dump two             # only one mapped client expected
state_dump
key super+t          # minimize the shown one; focus falls back to a hidden one
settle 300
dump minimized       # monocle must show the fallback window now
key super+shift+t    # restore: restored window is shown first frame
settle 400
dump restored
state_dump
