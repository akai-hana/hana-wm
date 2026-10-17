# S24 - dialog-float: a WM_TRANSIENT_FOR dialog maps floating (not tiled)
# and centered over its parent; the parent keeps its master tile untouched.
spawn_client A --w 640 --h 480
settle 300
spawn_client D --w 400 --h 300 --transient A   # dialog of A, sized before map
settle 400
dump dialog
state_dump
# Server-truth gate: the dialog client rect is centered over the parent's
# client rect (the centering math itself is pinned headlessly by model_test).
check_centered_over D A
