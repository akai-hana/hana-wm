# S22 - re-exec restore: reload_hana saves the session, execs the binary in
# place (same pid, same Xvfb), and the fresh boot restore re-adopts the
# surviving windows at their saved geometry/homes.
#
# Requires the Mod+Shift+R = "reload_hana" binding from the harness config.
# The re-exec hand-off is: persist.save -> close X -> execNext -> boot
# restore (main.zig reads HANA_RESTORE, adopts root children, applies the
# persisted model level). Only assertions that run headless live here; the
# X-session-wide variant needs a real WM sitting under a display server.
spawn_client A
spawn_client B
spawn_client C
key super+shift+2      # move focused (newest, C) to ws2
settle 400
dump pre-reexec
state_dump             # baseline dump_state identity/geometry

pid_before="$HANA_PID"

key super+shift+r      # reload_hana: unconditional in-place re-exec
settle 1500            # save + exec + grab reclaim + restore boot settle

# The re-exec is an execv IN PLACE: same pid, same log file.
kill -0 "$HANA_PID" 2>/dev/null || {
	echo "FAIL: hana died across the re-exec" >&2
	return 1
}
[ "$HANA_PID" = "$pid_before" ] || {
	echo "FAIL: pid '$HANA_PID' changed across the in-place exec (was ${pid_before})" >&2
	return 1
}

dump post-reexec
state_dump

# Hand-off happened and the successor re-adopted its old windows.
grep -q "Re-executing new binary" "$HW_LOG" || {
	echo "FAIL: no re-exec hand-off in hana.log" >&2
	return 1
}
grep -q "Adopted .* pre-existing windows" "$HW_LOG" || {
	echo "FAIL: successor did not adopt the surviving windows" >&2
	return 1
}

# T10 server truth after the hand-off: every surviving tiled client keeps
# the configured border width on the SAME display.
check_borders 4 A B    # C now lives on ws2 (fullscreen-adjacent slate); A,B tiled on ws1

# A second re-exec must keep working (idempotence of the hand-off).
key super+shift+r
settle 1000
kill -0 "$HANA_PID" 2>/dev/null || {
	echo "FAIL: hana died across the second re-exec" >&2
	return 1
}
dump post-reexec-2