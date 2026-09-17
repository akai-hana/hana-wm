# S23 - reload-then-quit: a config reload keeps the session, and SIGTERM then
# ends it gracefully (clean shutdown log, no crash marker).
#
# The graceful path: SIGTERM -> signal self-pipe -> utils.quit -> event loop
# returns -> "Shutting down gracefully..." (src/main.zig) -> clean exit. A
# crash (SIGSEGV/SIGBUS) would additionally drop ~/hana-crash.log next to the
# harness's private $HOME; its absence proves the quit was intentional.
spawn_client A
spawn_client B
key super+shift+y        # reload (binary unchanged -> config hot-reload)
settle 500
dump after-reload

# The reload must not have killed the WM.
kill -0 "$HANA_PID" 2>/dev/null || {
	echo "FAIL: hana died during the config reload" >&2
	return 1
}

if [ -f "$HW_OUT/config-home/hana-crash.log" ]; then
	echo "FAIL: crash marker appeared during reload" >&2
	return 1
fi

kill -TERM "$HANA_PID"
_deadline=$(( $(date +%s) + 5 ))
while kill -0 "$HANA_PID" 2>/dev/null; do
	[ "$(date +%s)" -ge "$_deadline" ] && {
		echo "FAIL: hana did not exit after SIGTERM" >&2
		return 1
	}
	sleep 0.1
done

grep -q "Shutting down gracefully..." "$HW_LOG" || {
	echo "FAIL: missing graceful-shutdown log line" >&2
	return 1
}
if [ -f "$HW_OUT/config-home/hana-crash.log" ]; then
	echo "FAIL: crash marker present after SIGTERM quit" >&2
	return 1
fi
return 0