# TMP-fs-latency - temporary measurement scenario for the fullscreen-enter
# bar-hide latency optimization. Cycles fullscreen enter/exit so the [FSPROF]
# instrumentation (built via -Dprofile-key) accumulates per-toggle timings.
# NOT a golden scenario; consumed standalone and deleted afterwards.
spawn_client A
spawn_client B
settle 300
key super+f
settle 150
key super+f
settle 150
key super+f
settle 150
key super+f
settle 150
key super+f
settle 150
key super+f
settle 150
key super+f
settle 150
key super+f
settle 150
