# S08 — all-view: a hidden-workspace window gets mapped by the toggle (BC17).
spawn_client A       # lives on ws1
key super+shift+2    # move it to ws2 (hidden from ws1's perspective)
settle 300
spawn_client B       # second client stays on ws1
dump normal-ws1
key super+a          # all_workspaces toggle
settle 400
dump all-view        # both visible now, incl. the previously hidden one
key super+a          # toggle back off
settle 400
dump all-view-off
state_dump
