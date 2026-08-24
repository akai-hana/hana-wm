#!/bin/sh
# Shared helpers for hana's smoke-test harness.
#
# Sourced by run-scenario.sh; scenario scripts run in that shell and call
# these directly. Every function assumes the environment exported by
# run-scenario.sh: HW_DISPLAY, HW_OUT (scenario out dir), HW_LOG (hana log).
#
# DISPLAY DISCIPLINE: every X-calling command here MUST be prefixed with
# DISPLAY="$HW_DISPLAY". The harness may otherwise reach the developer's real
# session (synthetic keys included!).

HW_SETTLE_MS="${HW_SETTLE_MS:-350}"

# Press a key chord on the harness display, e.g. `key super+t`.
key() {
	DISPLAY="$HW_DISPLAY" xdotool key --clearmodifiers --delay 40 "$@" >/dev/null
	settle 120
}

# Launch a client detached from the harness shell so nothing blocks and
# nothing inherits our signal handlers. Args are the command line.
spawn() {
	DISPLAY="$HW_DISPLAY" setsid nohup "$@" >>"$HW_OUT/clients.log" 2>&1 &
}

# Spawn a named harness client (tools/xclient.c) and wait until it is
# visible. Names (A, B, C, ...) let dumps and searches address instances.
spawn_client() {
	_name="$1"
	shift
	spawn "$HARNESS_ROOT/.cache/xclient" --name "$_name" "$@"
	wait_named "$_name" 1
}

# Legacy-style multi-count spawn helper kept for readability in scenarios:
# spawn_client A; spawn_client B; ... reads better than counters.
wait_named() {
	_name="$1"; _n="${2:-1}"; _deadline=$(( $(date +%s) + ${3:-5} ))
	while :; do
		_c=$(DISPLAY="$HW_DISPLAY" xdotool search --onlyvisible --name "^$_name\$" 2>/dev/null | wc -l)
		[ "$_c" -ge "$_n" ] && return 0
		if [ "$(date +%s)" -ge "$_deadline" ]; then
			echo "TIMEOUT waiting for $_n x '$_name' (have $_c) on $HW_DISPLAY" >&2
			return 1
		fi
		sleep 0.1
	done
}

# Window-id lists scoped to the harness display. `client_id NAME` resolves a
# named client; multiple matches take the newest.
xwin_ids() {
	DISPLAY="$HW_DISPLAY" xdotool search --onlyvisible --class "${1:-XClient}"
}
newest_win() { xwin_ids "$@" | tail -1; }
oldest_win() { xwin_ids "$@" | head -1; }
client_id() {
	DISPLAY="$HW_DISPLAY" xdotool search --onlyvisible --name "^$1\$" | tail -1
}

settle() {
	sleep "${1:-$HW_SETTLE_MS}e-3" 2>/dev/null || sleep "$(awk "BEGIN{print ${1:-$HW_SETTLE_MS}/1000}")"
}

# Trigger hana's dump_state action; output lands in $HW_LOG.
state_dump() {
	key super+q
	settle 200
}

# Snapshot X truth into the scenario out dir:
#   snap-<label>.tree   xwininfo -root -tree (geometry/stacking/border widths)
#   snap-<label>.props  xprop -root         (EWMH root properties)
dump() {
	_label="$1"
	DISPLAY="$HW_DISPLAY" xwininfo -root -tree >"$HW_OUT/snap-$_label.tree.raw" 2>&1
	DISPLAY="$HW_DISPLAY" xprop -root >"$HW_OUT/snap-$_label.props.raw" 2>&1
}

# Compile-on-demand helper that sets a client's own border width
# (exercises the ConfigureRequest BW path, BC04/BC05). Cached in .cache/.
client_bw() {
	_win="$1"; _bw="$2"
	_tool="$HARNESS_ROOT/.cache/setbw"
	if [ ! -x "$_tool" ]; then
		mkdir -p "$HARNESS_ROOT/.cache"
		cc -o "$_tool" "$HARNESS_ROOT/tools/setbw.c" -lX11 || return 1
	fi
	DISPLAY="$HW_DISPLAY" "$_tool" "$_win" "$_bw"
}

# Focused window id parsed from the most recent STATE DUMP in $HW_LOG.
focused_from_dump() {
	awk '/STATE DUMP/{found=NR} found && /Focused:/ && NR>found {print $2; exit}' "$HW_LOG"
}

# Send a _NET_WM_STATE fullscreen ClientMessage as a real client would
# (exercises the WM's client-message path, fix P0-3). Cached in .cache/.
ewmh_fs() {
	_win="$1"; _action="$2"
	_tool="$HARNESS_ROOT/.cache/ewmhfs"
	if [ ! -x "$_tool" ]; then
		mkdir -p "$HARNESS_ROOT/.cache"
		cc -O2 -o "$_tool" "$HARNESS_ROOT/tools/ewmhfs.c" -lX11 || return 1
	fi
	DISPLAY="$HW_DISPLAY" "$_tool" "$_win" "$_action"
}

# Send a mixed-mask ConfigureRequest (geometry [+ border width]) as a real
# client would (exercises the WM's ConfigureRequest decision paths, ND-14).
client_geom() {
	_win="$1"; _x="$2"; _y="$3"; _w="$4"; _h="$5"; _bw="${6:-}"
	_tool="$HARNESS_ROOT/.cache/setgeom"
	if [ ! -x "$_tool" ]; then
		mkdir -p "$HARNESS_ROOT/.cache"
		cc -o "$_tool" "$HARNESS_ROOT/tools/setgeom.c" -lX11 || return 1
	fi
	if [ -n "$_bw" ]; then
		DISPLAY="$HW_DISPLAY" "$_tool" "$_win" "$_x" "$_y" "$_w" "$_h" "$_bw"
	else
		DISPLAY="$HW_DISPLAY" "$_tool" "$_win" "$_x" "$_y" "$_w" "$_h"
	fi
}
