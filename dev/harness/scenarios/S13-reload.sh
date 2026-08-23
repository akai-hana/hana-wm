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

# BC20 hard assertion: query the SERVER for actual border widths. Golden log
# comparison alone missed a regression where the sweep silently kept the
# pre-reload width (stale init-cached value).
{
	for n in A B; do
		_id=$(client_id "$n")
		_bw=$(DISPLAY="$HW_DISPLAY" xwininfo -stats -id "$_id" | awk '/Border width:/ {print $3}')
		echo "$n border_width=$_bw"
	done
} >"$HW_OUT/borders-after-reload.norm"
while read -r _n _pair; do
	_bw=${_pair#*=}
	[ "$_bw" = "7" ] || {
		echo "FAIL: $_n border width is '$_bw', expected 7 after reload" >&2
		exit 1
	}
done <"$HW_OUT/borders-after-reload.norm"
