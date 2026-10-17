# S25 - bar-pixels: P1-21 golden-pixel capture of the bar window.
#
# No clients and no dynamic readouts (see S25-bar-pixels.config.toml): the
# bar reaches a fixed picture on its first frame. Two captures spaced 400ms
# apart must be byte-identical -- that is the scenario's own determinism
# proof; a segment that keeps ticking (clock creep, carousel, hover) fails
# here instead of poisoning the golden. bar_shot writes the normalized
# cell-ink grid to bar.norm, which run-scenario.sh diffs against
# golden/S25-bar-pixels/bar.norm under --compare.
bar_shot || return 1
cp "$HW_OUT/bar.norm" "$HW_OUT/bar.first"
settle 400
bar_shot || return 1
if ! cmp -s "$HW_OUT/bar.first" "$HW_OUT/bar.norm"; then
	echo "S25: bar pixels changed across 400ms (non-static segment?)" >&2
	return 1
fi
rm -f "$HW_OUT/bar.first" "$HW_OUT/barshot.err"
state_dump
