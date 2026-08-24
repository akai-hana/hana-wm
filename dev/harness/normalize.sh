#!/bin/sh
# Normalize volatile output from harness dumps so runs are comparable.
#
#   - Window ids (0x + >=5 hex digits) -> stable tokens (W01, W02, ...) in
#     first-appearance order. Creation order is deterministic per scenario,
#     so token assignment is stable across runs.
#   - PIDs (_NET_WM_PID) -> PID
#   - Wall-clock times (bar clock segment) -> TIME
#   - bench wall-time figures -> T us (round-trip/window counts kept)
#   - ANSI escapes dropped.
#
# Usage: normalize.sh <file...>   (rewrites in place)
# Env:   HW_KEEP_RAW=1 writes <file>.norm instead of in-place.

for f in "$@"; do
	[ -f "$f" ] || continue
	perl -e '
		my %map; my $n = 0;
		while (<>) {
			s/\e\[[0-9;]*[A-Za-z]//g;
			next if /^Fontconfig warning:/;   # intermittent fontconfig init noise
			# NoFont draw attempts: the minimal Xvfb has no usable fonts, so
			# how many of these fire depends on where poll wakeups land
			# relative to scenario timing. Unreachable on real systems.
			next if /Best-effort op failed \(bar drawSegment\): error\.NoFont/;
			s/(_NET_WM_PID\(CARDINAL\) = )\d+/${1}PID/g;
			s/\b\d{1,2}:\d{2}(?::\d{2})?\b/TIME/g;
			s/(bench: title capture: .*), \d+ us/$1, T us/g;
			# Window ids: 0x-prefixed (xwininfo/xprop) AND bare >=6-hex-digit
			# forms — including PURE DECIMAL ones, because dump_state prints
			# its Focused:/window ids in decimal ({d}, e.g. 800001). Verified
			# ND-24: restricting this to hex-letter-bearing tokens broke every
			# golden (decimal ids stopped tokenizing); the ordering-dependence
			# concern is neutralized by per-scenario determinism, so the
			# original eat-decimals behavior is load-bearing and stays.
			s{(0x[0-9a-fA-F]{5,}|(?<![0-9A-Fa-f])(?:0[xX])?[0-9A-Fa-f]{6,}(?![0-9A-Fa-f]))}
			 { exists $map{$1} ? $map{$1} : ($map{$1} = sprintf("W%02d", ++$n)) }ge;
			print;
		}
	' "$f" >"$f.norm"
	if [ "${HW_KEEP_RAW:-0}" = "1" ]; then
		mv "$f.norm" "${f%.raw}.norm"
	else
		mv "$f.norm" "$f"
	fi
done
