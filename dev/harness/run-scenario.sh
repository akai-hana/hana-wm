#!/bin/sh
# Smoke-test harness for hana: run scenarios against an isolated Xvfb :99.
#
# Usage:
#   ./run-scenario.sh S01-spawn-tiled [S02-close ...]   run scenarios
#   --golden  capture results into golden/ instead of only out/
#   --compare compare each scenario against golden/ (semantic: geometry + EWMH + STATE DUMP)
#   --compare-raw  byte-exact diff of all normalized artifacts (old behavior)
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
GOLDEN=0; COMPARE=0; COMPARE_RAW=0; KEEP=0

while [ $# -gt 0 ]; do
	case "$1" in
		--golden)       GOLDEN=1 ;;
		--compare)      COMPARE=1 ;;
		--compare-raw)  COMPARE_RAW=1 ;;
		--keep)         KEEP=1 ;;
		-*)             echo "unknown flag: $1" >&2; exit 2 ;;
		*)              break ;;
	esac
	shift
done

[ $# -ge 1 ] || { sed -n '2,22p' "$0"; exit 2; }
[ -x "$HANA_BIN" ] || {
	echo "hana binary missing at $HANA_BIN (build with: zig build -Doptimize=Debug)" >&2
	exit 1
}
for tool in xdotool xprop xwininfo perl xset; do
	command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done

if [ "${BUILD_DEBUG:-0}" = "1" ]; then
	# Debug is NOT the default (bare `zig build` is ReleaseFast); the
	# scenarios' log assertions need the debug/info sites a release build
	# comptime-elides, so pass the flag explicitly.
	(cd "$REPO_ROOT" && zig build -Doptimize=Debug) || exit 1
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
	rm -rf "$out"; mkdir -p "$out" "$out/run"

	# Private config tree so scenario runs never touch the repo copy.
	cp -R "$HARNESS_ROOT/config-home" "$out/config-home"
	if [ -f "$HARNESS_ROOT/scenarios/$sc.config.toml" ]; then
		cp "$HARNESS_ROOT/scenarios/$sc.config.toml" "$out/config-home/hana/config.toml"
	fi

	# Fresh server. Fail politely if something already owns the display.
	# The probe goes through xset: exit 127 means the tool itself is broken
	# (never treat that as "display free" and never touch the lock), exit 0
	# means a server already owns the display, and any other non-zero means
	# no server -- only then is it safe to clear a stale lock and start Xvfb.
	DISPLAY="$HW_DISPLAY" xset q >/dev/null 2>&1
	xset_rc=$?
	if [ "$xset_rc" -eq 127 ]; then
		echo "FAIL $sc (xset unusable; cannot probe display $HW_DISPLAY)" >&2
		failures="$failures $sc"
		return 1
	fi
	if [ "$xset_rc" -eq 0 ]; then
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

	# P1-21 font pin: a PRIVATE fontconfig that exposes only the harness's
	# own font (fonts/) with antialiasing and hinting OFF, so every glyph
	# pixel is exact and identical on every machine the harness runs on --
	# this is what makes the S25 bar golden-pixel dump comparable instead of
	# fontconfig/freetype-dependent. Written per run (absolute paths), read
	# by fontconfig/Pango inside hana at startup; nothing else on the
	# display consults it.
	FONTCONF="$out/fonts.conf"
	{
		printf '%s\n' '<?xml version="1.0"?>'
		printf '%s\n' '<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">'
		printf '%s\n' '<fontconfig>'
		printf '  <dir>%s</dir>\n' "$HARNESS_ROOT/fonts"
		printf '  <cachedir>%s</cachedir>\n' "$out/fontcache"
		printf '%s\n' '  <match target="font">'
		printf '%s\n' '    <edit name="antialias" mode="assign"><bool>false</bool></edit>'
		printf '%s\n' '    <edit name="hinting" mode="assign"><bool>false</bool></edit>'
		printf '%s\n' '    <edit name="hintstyle" mode="assign"><const>hintnone</const></edit>'
		printf '%s\n' '    <edit name="rgba" mode="assign"><const>none</const></edit>'
		printf '%s\n' '    <edit name="lcdfilter" mode="assign"><const>none</const></edit>'
		printf '%s\n' '  </match>'
		printf '%s\n' '</fontconfig>'
	} >"$FONTCONF"

	# Boot hana with an isolated environment. A per-run XDG_RUNTIME_DIR
	# keeps any runtime socket/state path private to THIS scenario, and
	# HANA_PID is exported so scenarios can kill/reload hana directly.
	DISPLAY="$HW_DISPLAY" \
	XDG_CONFIG_HOME="$out/config-home" \
	HOME="$out/config-home" \
	XDG_RUNTIME_DIR="$out/run" \
	FONTCONFIG_FILE="$FONTCONF" \
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
	# EXPORT the harness vars. A VAR=val prefix on the `.` command
	# expires when sourcing returns, so helpers called afterwards
	# (state_dump_final -> dump/state_dump) saw unbound HW_OUT/HW_LOG.
	export HW_DISPLAY HW_OUT="$out" HW_LOG="$out/hana.log" HARNESS_ROOT="$HARNESS_ROOT" HANA_PID="$hana_pid"
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

	# Signal log (harness hardening): the WM-internal-truth subset of
	# hana's log. Warnings/errors (dropped requests, BadWindow probes),
	# state dumps (registry counts, focus) and hover-focus decisions.
	# Included in golden diffs so state divergence can't hide behind tree
	# snapshots while noisy debug lines stay out of the comparison.
	# Excluded: bar drawSegment NoFont warnings -- the minimal Xvfb
	# environment has no fontconfig setup, so their count depends on where
	# poll wakeups land relative to scenario timing (nondeterministic here,
	# unreachable on real systems where fonts exist).
	# Line 1 is the sig-format sentinel: a golden recorded against an older
	# log-tag era fails the sentinel check with "re-record" instead of one
	# confusing diff per compared field. Bump SIG_FORMAT on any change to
	# the field set or the log-tag format.
	SIG_FORMAT=3
	{
		printf '# sig-format: %s\n' "$SIG_FORMAT"
		grep -E "error:|warning:|STATE DUMP|Focused:|Total windows|WS[0-9]+: |MAYBE_FOCUS|Suppress focus" \
			"$out/hana.log.norm" \
			| grep -v "Best-effort op failed (bar drawSegment): error.NoFont" || :
	} >"$out/hana.log.sig"

	if [ "$rc" -ne 0 ]; then
		echo "FAIL $sc (scenario body rc=$rc)"
		failures="$failures $sc"
		return 1
	fi

	if [ "$COMPARE" = "1" ] || [ "$COMPARE_RAW" = "1" ]; then
		gold="$HARNESS_ROOT/golden/$sc"
		if [ ! -d "$gold" ]; then
			# D4: under --compare a missing golden is a hard failure, never a
			# silent pass. (A plain run without --compare never enters this
			# block, so it stays lenient by construction.)
			echo "FAIL $sc (no golden dir ${gold#$HARNESS_ROOT/}; re-record with --golden)"
			failures="$failures $sc"
		else
			diff_file="${TMPDIR:-/tmp}/hana-diff-$sc.txt"
			> "$diff_file"
			fail=0

			if [ "$COMPARE_RAW" = "1" ]; then
				# Raw mode: byte-exact diff of all normalized artifacts
				if diff -ru "$gold" "$out" --exclude=config-home --exclude='*.raw' --exclude=xvfb.log --exclude=hana.log --exclude=clients.log >>"$diff_file" 2>&1; then
					echo "PASS $sc (parity)"
				else
					echo "DIFF $sc (see $diff_file)"
					failures="$failures $sc"
				fi
			else
				# Semantic mode: compare only structural invariants.
				# Version sentinel FIRST: a golden from a previous log-tag
				# era fails here with "re-record" instead of one confusing
				# diff per field/file below.
				gold_sig_head=$(head -n 1 "$gold/hana.log.sig" 2>/dev/null || echo "(missing)")
				out_sig_head=$(head -n 1 "$out/hana.log.sig" 2>/dev/null || echo "(missing)")
				if [ "$gold_sig_head" != "$out_sig_head" ]; then
					echo "  SIG-FORMAT (gold='$gold_sig_head' out='$out_sig_head'; re-record with --golden)" >> "$diff_file"
					echo "DIFF $sc (see $diff_file)"
					failures="$failures $sc"
					return 0
				fi

				# Geometry trees + EWMH props: byte-exact (core correctness)
				for f in "$gold"/snap-*.tree.norm "$gold"/snap-*.props.norm; do
					[ -f "$f" ] || continue
					bn=$(basename "$f")
					if ! diff -q "$f" "$out/$bn" >/dev/null 2>&1; then
						echo "  DIFF $bn" >> "$diff_file"
						diff -u "$f" "$out/$bn" >> "$diff_file" 2>&1
						fail=1
					fi
				done

				# S13 borders assertion (explicit BW invariant)
				if [ -f "$gold/borders-after-reload.norm" ]; then
					if ! diff -q "$gold/borders-after-reload.norm" "$out/borders-after-reload.norm" >/dev/null 2>&1; then
						echo "  DIFF borders-after-reload.norm" >> "$diff_file"
						diff -u "$gold/borders-after-reload.norm" "$out/borders-after-reload.norm" >> "$diff_file" 2>&1
						fail=1
					fi
				fi

				# P1-21 bar golden-pixel dump: the normalized cell-ink grid of
			# the bar window. Presence is asserted from EITHER side, so a
			# scenario that silently stopped capturing pixels cannot pass
			# against a golden that has them (and vice versa).
			if [ -f "$gold/bar.norm" ] || [ -f "$out/bar.norm" ]; then
				if ! diff -q "$gold/bar.norm" "$out/bar.norm" >/dev/null 2>&1; then
					echo "  DIFF bar.norm" >> "$diff_file"
					diff -u "$gold/bar.norm" "$out/bar.norm" >> "$diff_file" 2>&1
					fail=1
				fi
			fi

			# STATE DUMP fields: compare last occurrence per field from hana.log.sig
				for field in "Focused:" "Total windows:" "Suppress focus:" "WS[0-9]+:" "Tiling enabled:" "Tiling layout:" "Tiled windows:"; do
					gold_val=$(grep -E "$field" "$gold/hana.log.sig" 2>/dev/null | tail -1)
					out_val=$(grep -E "$field" "$out/hana.log.sig" 2>/dev/null | tail -1)
					if [ "$gold_val" != "$out_val" ]; then
						echo "  DIFF $field" >> "$diff_file"
						printf "  - gold: %s\n" "$gold_val" >> "$diff_file"
						printf "  + out:  %s\n" "$out_val" >> "$diff_file"
						fail=1
					fi
				done

				if [ "$fail" = "0" ]; then
					echo "PASS $sc (parity)"
				else
					echo "DIFF $sc (see $diff_file)"
					failures="$failures $sc"
				fi
			fi
		fi
	else
		echo "OK   $sc"
	fi

	if [ "$GOLDEN" = "1" ]; then
		gold="$HARNESS_ROOT/golden/$sc"
		rm -rf "$gold"; mkdir -p "$gold"
		find "$out" -maxdepth 1 \( -name '*.norm' ! -name 'hana.log.norm' -o -name 'hana.log.sig' \) -exec cp {} "$gold/" \;
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
