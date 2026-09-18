# S02 - close: closing the focused window relayouts without holes.
#
# The focus order into the stack is an implementation detail, so this does NOT
# assume which window `super+j` lands on: it closes whatever is focused and
# then verifies that exactly one client disappeared, the survivors keep the
# configured border width, and the remaining windows re-tile without holes.
spawn_client A
spawn_client B
spawn_client C
dump three
state_dump
key super+j          # move focus off the initial window into the stack
state_dump
key super+shift+f    # close the focused window
settle 400
dump two

# T10 server-truth gate on the surviving windows (exactly two must remain).
survivors=""
for n in A B C; do
	DISPLAY="$HW_DISPLAY" xdotool search --onlyvisible --name "^$n\$" >/dev/null 2>&1 &&
		survivors="$survivors $n"
done
set -- $survivors
[ $# = 2 ] || {
	echo "FAIL: expected 2 survivors after close, got:${survivors:-<none>}" >&2
	return 1
}
check_borders 4 "$@"

key super+shift+f    # close again
settle 400
dump one

# Exactly one client must remain, still at the configured border width.
remaining=""
for n in A B C; do
	DISPLAY="$HW_DISPLAY" xdotool search --onlyvisible --name "^$n\$" >/dev/null 2>&1 &&
		remaining="$remaining $n"
done
set -- $remaining
[ $# = 1 ] || {
	echo "FAIL: expected 1 survivor after second close, got:${remaining:-<none>}" >&2
	return 1
}
check_borders 4 "$@"
