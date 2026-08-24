#!/bin/sh
# Smoke-test harness for hana: run scenarios against an isolated Xvfb :99.
#
# Usage:
#   ./run-scenario.sh S01-spawn-tiled [S02-close ...]   run scenarios
#   --golden  capture results into golden/ instead of only out/
#   --compare diff each scenario's normalized output against golden/ after running
#   --keep    keep Xvfb/hana alive after the last scenario (interactive debugging)
#
# Env:
#   HANA_BIN         binary to test      (default ../../zig-out/bin/hana, i.e. repo-relative)
#   BUILD_DEBUG=1    build a Debug binary first (dump_state/info logs need it)
#   HARNESS_DISPLAY  X display to use    (default :99)
#
# Layout:
#   config-home/hana/config.toml   base harness config (copied per run)
#   scenarios/<SC>.sh              scenario body (sourced)
#   scenarios/<SC>.config.toml     optional whole-config override for <SC>
#   out/<SC>/                      raw + normalized artifacts
#   golden/<SC>/                   recorded baseline outputs
set -u

HARNESS_ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HARNESS_ROOT/../.." && pwd)"
HANA_BIN="${HANA_BIN:-$REPO_ROOT/zig-out/bin/hana}"
HW_DISPLAY="${HARNESS_DISPLAY:-:99}"
GOLDEN=0; COMPARE=0; KEEP=0

while [ $# -gt 0 ]; do
	case "$1" in
		--golden)  GOLDEN=1 ;;
		--compare) COMPARE=1 ;;
		--keep)    KEEP=1 ;;
		-*)        echo "unknown flag: $1" >&2; exit 2 ;;
		*)         break ;;
	esac
	shift
done

[ $# -ge 1 ] || { sed -n '2,22p' "$0"; exit 2; }
[ -x "$HANA_BIN" ] || {
	echo "hana binary missing at $HANA_BIN (build with: zig build -Doptimize=Debug)" >&2
	exit 1
}
for tool in xdotool xprop xwininfo perl; do
	command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done

if [ "${BUILD_DEBUG:-0}" = "1" ]; then
	(cd "$REPO_ROOT" && zig build) || exit 1
fi

# Build harness clients once.
mkdir -p "$HARNESS_ROOT/.cache"
[ -x "$HARNESS_ROOT/.cache/xclient" ] || \
	cc -O2 -o "$HARNESS_ROOT/.cache/xclient" "$HARNESS_ROOT/tools/xclient.c" -lX11 || {
	echo "failed to build tools/xclient.c (need cc + libX11)" >&2; exit 1;
}
[ -x "$HARNESS_ROOT/.cache/setbw" ] || \
	cc -O2 -o "$HARNESS_ROOT/.cache/setbw" "$HARNESS_ROOT/tools/setbw.c" -lX11 || {
	echo "warning: setbw not built; S12 will fail" >&2;
}

failures=""

run_one() {
	sc="$1"
	sc_file="$HARNESS_ROOT/scenarios/$sc.sh"
	[ -f "$sc_file" ] || { echo "SKIP $sc (no such scenario)"; return 1; }

	out="$HARNESS_ROOT/out/$sc"
	rm -rf "$out"; mkdir -p "$out"

	# Private config tree so scenario runs never touch the repo copy.
	cp -R "$HARNESS_ROOT/config-home" "$out/config-home"
	if [ -f "$HARNESS_ROOT/scenarios/$sc.config.toml" ]; then
		cp "$HARNESS_ROOT/scenarios/$sc.config.toml" "$out/config-home/hana/config.toml"
	fi

	# Fresh server. Fail politely if something already owns the display.
	if DISPLAY="$HW_DISPLAY" xset q >/dev/null 2>&1; then
		echo "FAIL $sc (display $HW_DISPLAY already in use)" >&2
		failures="$failures $sc"
		return 1
	fi
	rm -f "/tmp/.X${HW_DISPLAY#:}-lock"
	setsid nohup Xvfb "$HW_DISPLAY" -screen 0 1280x800x24 -ac -nolisten tcp -dpi 96 \
		>"$out/xvfb.log" 2>&1 &
	xvfb_pid=$!

	deadline=$(( $(date +%s) + 8 ))
	until DISPLAY="$HW_DISPLAY" xset q >/dev/null 2>&1; do
		if [ "$(date +%s)" -ge "$deadline" ] || ! kill -0 "$xvfb_pid" 2>/dev/null; then
			echo "FAIL $sc (Xvfb did not start; see $out/xvfb.log)" >&2
			return 1
		fi
		sleep 0.2
	done

	# Boot hana with an isolated environment.
	DISPLAY="$HW_DISPLAY" \
	XDG_CONFIG_HOME="$out/config-home" \
	HOME="$out/config-home" \
	setsid nohup "$HANA_BIN" >"$out/hana.log" 2>&1 &
	hana_pid=$!

	deadline=$(( $(date +%s) + 10 ))
	until DISPLAY="$HW_DISPLAY" xprop -root _NET_SUPPORTING_WM_CHECK >/dev/null 2>&1; do
		if ! kill -0 "$hana_pid" 2>/dev/null; then
			echo "FAIL $sc (hana exited during boot)" >&2
			tail -5 "$out/hana.log" >&2
			return 1
		fi
		if [ "$(date +%s)" -ge "$deadline" ]; then
			echo "FAIL $sc (WM never claimed the display)" >&2
			return 1
		fi
		sleep 0.2
	done
	settle 300

	# Run the scenario body in this shell.
	# ND-24: EXPORT the harness vars — a VAR=val prefix on the `.` command
	# expires when sourcing returns, so helpers called afterwards
	# (state_dump_final -> dump/state_dump) saw unbound HW_OUT/HW_LOG.
	export HW_DISPLAY HW_OUT="$out" HW_LOG="$out/hana.log" HARNESS_ROOT="$HARNESS_ROOT"
	. "$sc_file"
	rc=$?

	state_dump_final() { state_dump; dump final; }
	state_dump_final

	# Stop the world, in order (--keep leaves both alive for debugging).
	if [ "$KEEP" = "1" ]; then
		echo "KEEP $sc: hana pid=$hana_pid on $HW_DISPLAY (Xvfb pid=$xvfb_pid); kill them when done."
		return 0
	fi
	kill "$hana_pid" 2>/dev/null
	sleep 0.3
	kill "$xvfb_pid" 2>/dev/null
	wait 2>/dev/null

	# Normalize everything volatile.
	HW_KEEP_RAW=1 "$HARNESS_ROOT/normalize.sh" "$out"/snap-*.tree.raw "$out"/snap-*.props.raw "$out/hana.log"

	grep -h "bench:" "$out/hana.log.norm" >"$out/bench.txt" 2>/dev/null || : >"$out/bench.txt"

	# Signal log (harness hardening): the WM-internal-truth subset of
	# hana's log — warnings/errors (dropped requests, BadWindow probes),
	# state dumps (registry counts, focus) and hover-focus decisions.
	# Included in golden diffs so state divergence can't hide behind tree
	# snapshots while noisy debug lines stay out of the comparison.
	# Excluded: bar drawSegment NoFont warnings -- the minimal Xvfb
	# environment has no fontconfig setup, so their count depends on where
	# poll wakeups land relative to scenario timing (nondeterministic here,
	# unreachable on real systems where fonts exist).
	grep -E "error:|warning:|STATE DUMP|Focused:|Total windows|WS[0-9]+: |MAYBE_FOCUS|Suppress focus" \
		"$out/hana.log.norm" \
		| grep -v "Best-effort op failed (bar drawSegment): error.NoFont" \
		>"$out/hana.log.sig" 2>/dev/null || : >"$out/hana.log.sig"

	if [ "$rc" -ne 0 ]; then
		echo "FAIL $sc (scenario body rc=$rc)"
		failures="$failures $sc"
		return 1
	fi

	if [ "$COMPARE" = "1" ]; then
		gold="$HARNESS_ROOT/golden/$sc"
		if [ ! -d "$gold" ]; then
			echo "NOCOMPARE $sc (no goldens)"
		else
			if diff -ru "$gold" "$out" --exclude=config-home --exclude='*.raw' --exclude=xvfb.log --exclude=hana.log --exclude=clients.log >${TMPDIR:-/tmp}/hana-diff-$sc.txt 2>&1; then
				echo "PASS $sc (parity)"
			else
				echo "DIFF $sc (see ${TMPDIR:-/tmp}/hana-diff-$sc.txt)"
				failures="$failures $sc"
			fi
		fi
	else
		echo "OK   $sc"
	fi

	if [ "$GOLDEN" = "1" ]; then
		gold="$HARNESS_ROOT/golden/$sc"
		rm -rf "$gold"; mkdir -p "$gold"
		find "$out" -maxdepth 1 \( -name '*.norm' -o -name 'bench.txt' -o -name 'hana.log.sig' \) -exec cp {} "$gold/" \;
		echo "GOLDEN $sc captured -> ${gold#$REPO_ROOT/}"
	fi

	return 0
}

. "$HARNESS_ROOT/lib/common.sh"

for sc in "$@"; do
	run_one "$sc"
done

[ -z "$failures" ] || { echo "failed:$failures" >&2; exit 1; }
exit 0
