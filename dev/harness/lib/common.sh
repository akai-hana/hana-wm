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
# Fail-loud: a dead display or dropped grab must never pass silently.
key() {
	DISPLAY="$HW_DISPLAY" xdotool key --clearmodifiers --delay 40 "$@" >/dev/null || {
		echo "key: xdotool key $* failed on $HW_DISPLAY" >&2
		exit 1
	}
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

# Wait until `_n` windows named `_name` exist, whether viewable or hidden
# (unmapped/parked). Layouts like monocle park non-shown windows, which
# `xdotool search --onlyvisible` cannot see; waiting on existence keeps the
# spawn deterministic instead of emitting a spurious visibility TIMEOUT.
wait_named_any() {
	_name="$1"; _n="${2:-1}"; _deadline=$(( $(date +%s) + ${3:-5} ))
	while :; do
		_c=$(DISPLAY="$HW_DISPLAY" xdotool search --name "^$_name\$" 2>/dev/null | wc -l)
		[ "$_c" -ge "$_n" ] && return 0
		if [ "$(date +%s)" -ge "$_deadline" ]; then
			echo "TIMEOUT waiting for $_n x '$_name' to exist (have $_c) on $HW_DISPLAY" >&2
			return 1
		fi
		sleep 0.1
	done
}

# Spawn a named client that the active layout may immediately park hidden
# (e.g. a non-shown monocle window). Waits for existence, not visibility.
spawn_client_hidden() {
	_name="$1"
	shift
	spawn "$HARNESS_ROOT/.cache/xclient" --name "$_name" "$@"
	wait_named_any "$_name" 1
}

# Resolves a named client to its window id (multiple matches take the newest).
client_id() {
	DISPLAY="$HW_DISPLAY" xdotool search --onlyvisible --name "^$1\$" | tail -1
}

# Fractional-second sleep; ms input matches the scenario idiom (`settle 300`).
settle() {
	sleep "$(awk "BEGIN{print ${1:-$HW_SETTLE_MS}/1000}")"
}

# D22/P2-75: condition polling with deadlines, replacing fixed sleeps.
# Every helper polls up to ${2:-5} seconds and fails loudly with the
# OBSERVED state against what was expected -- a hang and a silent early
# pass both lose the diagnosis.

# Wait until hana's EWMH _NET_ACTIVE_WINDOW names the expected client
# (or `null` when nothing should be focused). Polls X truth via xprop, so
# no key press is needed: it keeps working while the WM is between grabs
# (re-exec, reload) and never perturbs the _dump_seq sequence the
# focused_assert helpers wait on.
wait_focused() {
	_want="$1"; _deadline=$(( $(date +%s) + ${2:-5} ))
	if [ "$_want" = "null" ]; then
		_exp="0x0"
	else
		_id=$(client_id "$_want")
		[ -n "$_id" ] || { echo "FAIL wait_focused: no window '$_want'" >&2; return 1; }
		_exp=$(printf '0x%x' "$_id")
	fi
	while :; do
		_obs=$(DISPLAY="$HW_DISPLAY" xprop -root _NET_ACTIVE_WINDOW 2>/dev/null \
			| sed -n 's/.*# \(0x[0-9a-fA-F]*\).*/\1/p')
		[ -n "$_obs" ] || _obs=0x0
		[ "$_obs" = "$_exp" ] && return 0
		[ "$(date +%s)" -ge "$_deadline" ] && {
			echo "FAIL wait_focused: observed focus '$_obs', expected '$_exp' ($_want) after ${2:-5}s" >&2
			return 1
		}
		sleep 0.1
	done
}

# Wait until the LAST state dump reports exactly `_want` total windows.
# Each poll sends super+q and waits for a NEW dump, so the reading is
# post-key: during a re-exec's grab-less window the keys are dropped and
# the loop simply retries until the successor answers again. Uses its own
# sequence variable (`_w_seq`) and never touches `_dump_seq`.
wait_windows() {
	_want="$1"; _deadline=$(( $(date +%s) + ${2:-5} )); _w_obs="<no dump>"
	while :; do
		_w_seq=$(grep -c 'STATE DUMP' "$HW_LOG" 2>/dev/null) || _w_seq=0
		key super+q
		_w_inner=$(( $(date +%s) + 2 ))
		while :; do
			_w_n=$(grep -c 'STATE DUMP' "$HW_LOG" 2>/dev/null) || _w_n=0
			[ "$_w_n" -gt "$_w_seq" ] && break
			[ "$(date +%s)" -ge "$_w_inner" ] && break
			sleep 0.1
		done
		if [ "$_w_n" -gt "$_w_seq" ]; then
			# Re-read after the seq bump; a partially written dump parses
			# as empty and is retried on the next poll.
			_w_obs=$(grep 'Total windows:' "$HW_LOG" 2>/dev/null | tail -1 | awk '{print $NF}')
			[ "$_w_obs" = "$_want" ] && return 0
		fi
		[ "$(date +%s)" -ge "$_deadline" ] && {
			echo "FAIL wait_windows: observed total '${_w_obs:-<no dump>}', expected '$_want' after ${2:-5}s" >&2
			return 1
		}
		sleep 0.1
	done
}

# Wait until no window named `_name` exists at all (mapped or parked):
# xdotool search without --onlyvisible, same population wait_named_any
# counts, so a hide/park that ends in deletion or a plain close both land.
wait_gone() {
	_name="$1"; _deadline=$(( $(date +%s) + ${2:-5} ))
	while :; do
		_c=$(DISPLAY="$HW_DISPLAY" xdotool search --name "^$_name\$" 2>/dev/null | wc -l)
		[ "$_c" -eq 0 ] && return 0
		[ "$(date +%s)" -ge "$_deadline" ] && {
			echo "FAIL wait_gone: '$_name' still present ($_c matching) after ${2:-5}s" >&2
			return 1
		}
		sleep 0.1
	done
}

# Trigger hana's dump_state action; output lands in $HW_LOG. Records the
# pre-key STATE DUMP count in _dump_seq so focused_mid/focused_final can
# wait for THIS dump to land (a "log is quiet" heuristic races: the
# previous count is quiet too).
state_dump() {
	_dump_seq=$(grep -c 'STATE DUMP' "$HW_LOG" 2>/dev/null) || _dump_seq=0
	key super+q
}

# Snapshot X truth into the scenario out dir:
#   snap-<label>.tree   xwininfo -root -tree (geometry/stacking/border widths)
#   snap-<label>.props  xprop -root         (EWMH root properties)
dump() {
	_label="$1"
	DISPLAY="$HW_DISPLAY" xwininfo -root -tree >"$HW_OUT/snap-$_label.tree.raw" 2>&1
	DISPLAY="$HW_DISPLAY" xprop -root >"$HW_OUT/snap-$_label.props.raw" 2>&1
}

# The server's own border width for a window, via the same xwininfo -stats
# query S13's reload gate uses. This is X truth, not the WM's bookkeeping.
server_border_width() {
	_win="$1"
	DISPLAY="$HW_DISPLAY" xwininfo -stats -id "$_win" | awk '/Border width:/ {print $3; exit}'
}

# T10 server-truth gate: assert the SERVER-reported border width of every
# named tiled client equals the expectation (default: the harness config's
# border_width = 4). Catches WM-side bookkeeping regressions that a golden
# hana.log snapshot could mask. Fail-loud: any mismatch aborts the scenario.
check_borders() {
	_exp="${1:-4}"; shift
	_fail=0
	for _n in "$@"; do
		_id=$(client_id "$_n")
		[ -n "$_id" ] || { echo "FAIL: check_borders: no window '$_n'" >&2; _fail=1; continue; }
		_bw=$(server_border_width "$_id")
		[ "$_bw" = "$_exp" ] || {
			echo "FAIL: $_n server border width is '$_bw', expected $_exp" >&2
			_fail=1
		}
	done
	[ "$_fail" = "0" ] || return 1
}

# P1-11 server-truth gate: the named dialog's client rect must equal the
# dialog centered over the named parent's client rect -- the
# WM_TRANSIENT_FOR placement (the centering math itself is pinned
# headlessly by model_test's centerRectIn test). Fail-loud like check_borders.
check_centered_over() {
	_dlg="$1"; _par="$2"
	_did=$(client_id "$_dlg"); _pid=$(client_id "$_par")
	[ -n "$_did" ] || { echo "FAIL: check_centered_over: no window '$_dlg'" >&2; return 1; }
	[ -n "$_pid" ] || { echo "FAIL: check_centered_over: no window '$_par'" >&2; return 1; }
	set -- $(DISPLAY="$HW_DISPLAY" xwininfo -id "$_did" | awk '
		/Absolute upper-left X:/ {x=$NF}
		/Absolute upper-left Y:/ {y=$NF}
		/Width:/ {w=$NF}
		/Height:/ {h=$NF}
		END {print x, y, w, h}')
	_dx=$1 _dy=$2 _dw=$3 _dh=$4
	set -- $(DISPLAY="$HW_DISPLAY" xwininfo -id "$_pid" | awk '
		/Absolute upper-left X:/ {x=$NF}
		/Absolute upper-left Y:/ {y=$NF}
		/Width:/ {w=$NF}
		/Height:/ {h=$NF}
		END {print x, y, w, h}')
	_px=$1 _py=$2 _pw=$3 _ph=$4
	_ex=$(( _px + (_pw - _dw) / 2 ))
	_ey=$(( _py + (_ph - _dh) / 2 ))
	if [ "$_dx" != "$_ex" ] || [ "$_dy" != "$_ey" ]; then
		echo "FAIL: $_dlg at $_dx,$_dy is not centered over $_par at $_px,$_py ($_pw x $_ph): expected $_ex,$_ey" >&2
		return 1
	fi
}

compile_tool() {
	_tool="$1"; shift
	_src="$1"; shift
	if [ ! -x "$_tool" ]; then
		mkdir -p "$HARNESS_ROOT/.cache"
		cc -o "$_tool" "$_src" "$@" || return 1
	fi
}

# Compile-on-demand helper that sets a client's own border width
# (exercises the ConfigureRequest BW path). Cached in .cache/.
client_bw() {
	_win="$1"; _bw="$2"
	compile_tool "$HARNESS_ROOT/.cache/setbw" "$HARNESS_ROOT/tools/setbw.c" -lX11 || return 1
	DISPLAY="$HW_DISPLAY" "$_tool" "$_win" "$_bw"
}

# Focused window id from the most recent STATE DUMP in $HW_LOG: the bare
# hex id (e.g. 600001) or `null`. $NF, not $2: the raw line reads
# `info: [diagnostic] Focused:        <id>`; no `exit` -- the first dump's
# Focused line would win, so keep the LAST match instead.
focused_from_dump() {
	awk '/STATE DUMP/{found=NR} found && /Focused:/ && NR>found {got=$NF} END{if (found) print got}' "$HW_LOG"
}

# Assert the focus captured by the most recent state_dump against a named
# harness client (or the literal `null`). P1-42: the golden compare checks
# only the LAST occurrence per field (tail -1), so an intermediate focus
# flip goes unasserted there -- these helpers pin it at the point of use.
# focused_mid: an in-scenario (mid-run) expectation; focused_final: an
# explicit end-of-body expectation. Fail-loud: they return 1, and a
# mid-body call site must propagate with `|| return 1` (a bare statement
# would fall through to the scenario's final rc).
focused_assert() {
	_want="$1"; _label="$2"
	if [ "$_want" = "null" ]; then
		_exp="null"
	else
		_id=$(client_id "$_want")
		[ -n "$_id" ] || { echo "FAIL $_label: no window '$_want'" >&2; return 1; }
		# client_id is decimal (xdotool); the raw dump prints bare hex.
		_exp=$(printf '%x' "$_id")
	fi
	# Wait for the dump THIS assertion follows: state_dump recorded the
	# pre-key count in _dump_seq, so require a NEW dump (max ~2s) instead
	# of a quiet-log heuristic, which would race with the previous dump.
	_deadline=$(( $(date +%s) + 2 ))
	_n=0
	while :; do
		_n=$(grep -c 'STATE DUMP' "$HW_LOG" 2>/dev/null) || _n=0
		[ "$_n" -gt "${_dump_seq:-0}" ] && break
		[ "$(date +%s)" -ge "$_deadline" ] && break
		sleep 0.1
	done
	if [ "$_n" -le "${_dump_seq:-0}" ]; then
		echo "FAIL $_label: state dump never landed in $HW_LOG" >&2
		return 1
	fi
	_got=$(focused_from_dump)
	if [ "$_got" != "$_exp" ]; then
		echo "FAIL $_label: focus is '${_got:-<no dump>}' expected '$_exp' ($_want)" >&2
		return 1
	fi
}
focused_mid() { focused_assert "$1" focused_mid; }
focused_final() { focused_assert "$1" focused_final; }

# Send a _NET_WM_STATE fullscreen ClientMessage as a real client would
# (exercises the WM's client-message path). Cached in .cache/.
ewmh_fs() {
	_win="$1"; _action="$2"
	compile_tool "$HARNESS_ROOT/.cache/ewmhfs" "$HARNESS_ROOT/tools/ewmhfs.c" -O2 -lX11 || return 1
	DISPLAY="$HW_DISPLAY" "$_tool" "$_win" "$_action"
}

# Send a mixed-mask ConfigureRequest (geometry [+ border width]) as a real
# client would (exercises the WM's ConfigureRequest decision paths).
client_geom() {
	_win="$1"; _x="$2"; _y="$3"; _w="$4"; _h="$5"; _bw="${6:-}"
	compile_tool "$HARNESS_ROOT/.cache/setgeom" "$HARNESS_ROOT/tools/setgeom.c" -lX11 || return 1
	if [ -n "$_bw" ]; then
		DISPLAY="$HW_DISPLAY" "$_tool" "$_win" "$_x" "$_y" "$_w" "$_h" "$_bw"
	else
		DISPLAY="$HW_DISPLAY" "$_tool" "$_win" "$_x" "$_y" "$_w" "$_h"
	fi
}

# P1-21 golden-pixel gate: capture the bar window as a normalized cell-ink
# grid -> $HW_OUT/bar.norm (compared against golden/<sc>/bar.norm by
# run-scenario.sh's semantic diff, same as the borders assertion).
#
# The bar paints its first frame asynchronously; probe until a grid with any
# ink appears (deadline 5s) so the scenario cannot capture the pre-paint
# window. A bar that NEVER paints (fonts not pinned, no segments) fails
# loudly rather than recording an all-background golden.
bar_shot() {
	compile_tool "$HARNESS_ROOT/.cache/barshot" "$HARNESS_ROOT/tools/barshot.c" -lX11 || return 1
	_deadline=$(( $(date +%s) + 5 ))
	while :; do
		if DISPLAY="$HW_DISPLAY" "$HARNESS_ROOT/.cache/barshot" \
			>"$HW_OUT/bar.norm" 2>"$HW_OUT/barshot.err"; then
			# A pure-hex row with any non-zero cell = a painted frame
			# (the "bar WxH ..." header line can never match: it has spaces).
			grep -q '^[0-9a-f]*[1-9a-f][0-9a-f]*$' "$HW_OUT/bar.norm" && return 0
		fi
		if [ "$(date +%s)" -ge "$_deadline" ]; then
			echo "FAIL bar_shot: no painted bar frame on $HW_DISPLAY" >&2
			cat "$HW_OUT/barshot.err" >&2 2>/dev/null || :
			return 1
		fi
		sleep 0.2
	done
}
