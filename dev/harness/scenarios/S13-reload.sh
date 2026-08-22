# S13 — reload: border_width change sweeps once with correct widths (BC20).
spawn_client A
spawn_client B
dump before-reload
# Edit the run-private config copy: 4 -> 7.
sed -i 's/^border_width = 4$/border_width = 7/' "$HW_OUT/config-home/hana/config.toml"
key super+shift+y    # reload
settle 600
dump after-reload    # every tiled border now 7; hana.log must show no double sends
state_dump
