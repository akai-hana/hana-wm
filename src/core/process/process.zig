//! Process lifecycle: flags and fd plumbing (xcb-free, module-level atomics
//! shared between signal handlers, actions, and the event loop), the
//! in-place exec coordinator (binary reload via event-loop flag, also
//! xcb-free and model-free), and the signal self-pipe/dispatch: POSIX
//! signals routed through a self-pipe so the event loop can dispatch them
//! without signal-handler reentrancy. Config reloads (SIGHUP/reload_config)
//! are separate from re-exec.

const std = @import("std");

const log = @import("log");

const builtin = @import("builtin");

const spawn = @import("spawn");

/// Set to false by SIGTERM/SIGINT to break the main event loop.
pub var running = std.atomic.Value(bool).init(true);

/// Set to true by SIGHUP or the `reload_config` keybinding.
/// Consumed by `consumeReload` in the main event loop.
var should_reload = std.atomic.Value(bool).init(false);

/// Write end of the signal self-pipe (owned by `setup` below), registered via
/// `setSignalWriteFd`. The `reload_config` keybinding has no signal byte, so
/// `reload()` writes a wake byte here to poke the event loop out of poll
/// immediately instead of waiting for an unrelated signal.
var signal_write_fd: std.posix.fd_t = -1;

/// Byte `reload()` writes to the signal pipe to wake the event loop out of
/// poll. A pure wake token: the drain discards it and dispatches from the
/// real-signal bitmap, so no byte value collides with a signal.
const wake_byte: u8 = 0xff;

/// Registers the write end of the signal self-pipe so `reload()` can wake the
/// event loop. Pass -1 to unregister (teardown).
pub fn setSignalWriteFd(fd: std.posix.fd_t) void {
    signal_write_fd = fd;
}

/// Wakes the event loop out of poll by writing the wake byte, if the signal
/// pipe is registered. Lossy: a full (or unregistered) pipe drops the byte;
/// the event loop polls its flags every iteration, so a lost byte only delays
/// the action by one poll timeout at worst.
fn writeWakeByte() void {
    if (signal_write_fd >= 0)
        _ = std.os.linux.write(signal_write_fd, &[_]u8{wake_byte}, 1);
}

/// Gracefully stop the main event loop.
pub fn quit() void {
    running.store(false, .release);
}

/// Signals the main event loop to reload the user config.
///
/// Safe from any thread: the wake byte is a plain write, not a signal. If the
/// pipe is full (or not yet registered) the write is dropped; the event loop
/// also polls the flag itself every iteration, so a lost byte only delays the
/// reload by one poll timeout at worst.
pub fn reload() void {
    if (!should_reload.swap(true, .acq_rel)) writeWakeByte();
}

/// Wakes the event loop out of poll by writing the wake byte, without
/// touching any flag. The narrow version of `reload()`: `requestReexec` uses it so
/// its re-exec request (a separate flag, consumed by `consumeReexec`) is
/// noticed immediately instead of waiting for an unrelated signal. Same
/// lossy-write tolerance as `reload()`: the event loop polls its flags every
/// iteration, so a dropped byte only delays the action by one poll timeout.
pub fn wake() void {
    writeWakeByte();
}

/// Atomically consumes the reload flag.
/// Returns true exactly once per request, whichever call path checks first wins.
pub fn consumeReload() bool {
    return should_reload.swap(false, .acq_rel);
}

/// In-place exec coordinator (former restart.zig, merged 2026-10-10).

// libc bindings for execv/setenv (no Zig stdlib wrappers exist for them, and
// the executable links libc, so mirroring spawn.zig's pattern is the honest
// route). execv (not execvp) is deliberate: we hand it the absolute self
// path, so there is no PATH lookup; and as the variadic execv it inherits
// the process environ, which carries DISPLAY and HANA_RESTORE forward.
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
});

/// c_allocator-owned, NUL-terminated copy of `src`, or die: the re-exec
/// cannot proceed without the path, the X connection is already closed, and
/// there is nothing left to do but end the session.
fn mustDupeZ(src: []const u8, what: []const u8) [:0]const u8 {
    return std.heap.c_allocator.dupeZ(u8, src) catch {
        log.err("restart: out of memory copying {s}", .{what});
        std.process.exit(1);
    };
}

/// Null-terminated absolute path to exec on re-exec (readLink of
/// `/proc/self/exe`). c_allocator-owned, process-lifetime: never freed.
var exec_path_z: ?[:0]const u8 = null;

/// Re-exec request flag. Set by `requestReexec` (the `reload_hana` action and
/// SIGUSR1), consumed by `consumeReexec` in the main event loop.
var should_reexec = std.atomic.Value(bool).init(false);

/// Resolves the binary to exec on re-exec: the readLink of `/proc/self/exe`.
/// One-shot at startup, before any reload/reexec request can arrive.
pub fn init() void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.os.linux.readlinkat(std.os.linux.AT.FDCWD, "/proc/self/exe", &buf, buf.len);
    // readlinkat returns exactly `buf.len` (errno still SUCCESS) when the
    // path fills the buffer -- truncated, no NUL. The old code then dupeZ'd
    // the truncated bytes as the exec path. Treat a full buffer as
    // unresolvable so a re-exec can never hand execv a cut-off path.
    if (std.posix.errno(n) != .SUCCESS or n == buf.len) {
        log.warn(
            "restart: readlink /proc/self/exe failed or truncated; in-place re-exec disabled",
            .{},
        );
        exec_path_z = null;
    } else {
        exec_path_z = std.heap.c_allocator.dupeZ(u8, buf[0..n]) catch null;
    }
}

/// Unconditional re-exec (`reload_hana` action / SIGUSR1): re-exec the
/// current in-place binary, skipping any change check.
pub fn requestReexec() void {
    should_reexec.store(true, .release);
    wake();
}

/// Atomic, mirrors consumeReload: true exactly once per request.
/// Consumed by the event loop AFTER consumeReload (events.run checks reload
/// first, re-exec second).
pub fn consumeReexec() bool {
    return should_reexec.swap(false, .acq_rel);
}

/// The resolved path of the running image, still sentinel-terminated, for
/// callers that hand it to `execv`. Null when re-exec was never armed (init
/// saw no /proc). `execNext` takes this form so the hand-off does not
/// re-duplicate a string the process is already holding.
fn selfPathZ() ?[:0]const u8 {
    return exec_path_z;
}

/// The environment variables that carry the re-exec hand-off. The WRITER
/// (`execNext`) and the READER (boot, via `restorePathFromEnv`) have to agree
/// exactly, and both sides used to spell the names as string literals at their
/// own site. A typo on the reading side is the worst kind of bug here: the
/// lookup simply returns null, so a re-exec'd instance boots as a COLD boot
/// and silently adopts nothing, with no error anywhere.
pub const restore_env = "HANA_RESTORE";
pub const config_dir_env = "HANA_CONFIG_DIR";

/// The restore path a previous instance handed over, or null when this is a
/// cold boot. Borrowed from the process environment -- do not free, and do not
/// retain past the adoption.
pub fn restorePathFromEnv() ?[*:0]const u8 {
    return std.c.getenv(restore_env);
}

/// The complete re-exec hand-off, assembled once and owned by this module.
///
/// These three values used to travel separately: the event loop held the exec
/// path, built the restore path, and called into config for the snapshot path
/// before handing each to `execNext` as loose arguments. Three sources of truth
/// for one transition means the sequence has to be re-derived at every call
/// site, and nothing can assert the set is complete. Naming the record makes
/// "what crosses the hand-off" a single declaration.
pub const Handoff = struct {
    /// Sentinel-terminated (`selfPathZ()`); this process's own image.
    self_path: [:0]const u8,
    /// The session state file. Not sentinel-terminated: the only copy is made
    /// here, inside the call that needs it.
    restore_path: []const u8,
    /// Frozen last-good config directory, or null when no user config was ever
    /// loaded (a fallback-only session has nothing to pin).
    config_snapshot: ?[:0]const u8 = null,
};

/// The hand-off for this process, or null when re-exec was never armed
/// (`init` saw no `/proc`, so there is no exec path to hand over).
///
/// `config_snapshot` is passed in rather than resolved here: the snapshot
/// lives in the config layer, and importing config from `core/process` to fetch
/// one path would invert the dependency for no gain. The caller already has
/// both values; this only fixes their order and names them.
pub fn currentHandoff(restore_path: []const u8, config_snapshot: ?[:0]const u8) ?Handoff {
    const self_path = selfPathZ() orelse return null;
    return .{
        .self_path = self_path,
        .restore_path = restore_path,
        .config_snapshot = config_snapshot,
    };
}

/// Execs `self_path` IN PLACE, inheriting environ/DISPLAY. Never returns.
/// MUST be called only after the X connection is closed (handleReexec does):
/// a live inherited fd would keep the old client (and its root
/// SubstructureRedirect grab) alive while the fresh connection tries to
/// claim the same grab, and the server would reject the newcomer with
/// BadAccess.
///
/// Deliberately NO fork: the process identity (pid and parent) survives
/// the hand-off. Under startx the display lives exactly as long as the
/// session client (xinit -> Xsession -> .xinitrc -> this process); replacing
/// the image in place keeps that chain unbroken, so the successor boots into
/// a live server and the session only ends when the new WM actually exits.
/// (The original fork-then-exit design killed every supervised re-exec:
/// the parent's exit made the session script return and xinit tore down
/// Xorg mid-hand-off.)
///
/// The restore path crosses the hand-off in `restore_env`: execv inherits
/// environ, and Zig 0.16's classic `main() !void` cannot read argv, so the
/// environment is the one channel a fresh boot can see.
pub fn execNext(handoff: Handoff) noreturn {
    const self_z = handoff.self_path;
    const restore_z = mustDupeZ(handoff.restore_path, "restore path");

    if (c.setenv(restore_env, restore_z, 1) != 0) {
        log.err("restart: setenv failed", .{});
        std.process.exit(1);
    }
    if (handoff.config_snapshot) |snap_z|
        _ = c.setenv(config_dir_env, snap_z, 1);
    _ = c.execv(self_z, @ptrCast(&[_:null]?[*:0]const u8{ self_z, null }));
    // Only reachable when exec failed; the X connection is already closed,
    // so there is nothing left to do but end the session.
    log.err("restart: execv failed", .{});
    std.process.exit(1);
}

/// Signal self-pipe and dispatch (former signals.zig, merged 2026-10-11):
/// routes POSIX signals through a self-pipe so the event loop can dispatch
/// them safely without signal-handler reentrancy.
// End indices of the self-pipe: signal handlers write to pipe_write; the
// event loop polls pipe_read.
const pipe_read = 0;
const pipe_write = 1;

/// Bytes read per syscall from the self-pipe. The pipe holds only wake tokens
/// (whose value is ignored), so this is just a read size: big enough that a
/// coalesced burst is cleared in one call.
const drain_buf_size: usize = 16;

var signal_pipe: [2]std.posix.fd_t = .{ -1, -1 };

// Alternate-signal-stack backing store for the SIGUSR2 backtrace handler,
// which runs with SA.ONSTACK. 64 KiB is ~8x SIGSTKSZ (8 KiB on x86_64) so the
// handler never reaches the top of a tiny kernel-given area; static so no
// allocator is touched in signal context. align(16) so the stack pointer the
// kernel installs is ABI-aligned for a pushed frame.
var alt_stack_mem: [64 * 1024]u8 align(16) = undefined;

// Async-signal-safe pending-signal bitmap. The self-pipe byte is now only a
// WAKE TOKEN: a full pipe forces the handler to drain its backlog, so a byte
// can be discarded, and signal STATE must not ride on the byte. Instead the
// handler sets a bit here with a lock-free atomic OR, and the event loop
// consumes the whole word. A TERM/INT/reload delivered during a pipe-full
// burst therefore can never be lost (previously it could: dispatchSignal -- the
// only thing that sets the quit/reload flags -- ran solely off pipe bytes).
var pending_signals: std.atomic.Value(u64) = .init(0);

// Async-signal-safe handler: records the signal and wakes the loop.
fn signalHandler(signo: std.posix.SIG) callconv(.c) void {
    // The u64 bitmap only has 64 bits, so clamp rather than panic when the
    // runtime hands us a signal number past 63: a panic inside an
    // async-signal handler cannot unwind, it would abort the process. A
    // clamped signal still lands in the bitmap and still gets dispatched.
    const bit: u6 = @intCast(@min(@intFromEnum(signo), 63));
    _ = pending_signals.fetchOr(@as(u64, 1) << bit, .release);
    writeWakeToken();
}

/// The one byte written to the self-pipe. Its VALUE carries nothing: the
/// reader (`drainAndDispatch`) drains whatever is there and then consumes the
/// whole `pending_signals` bitmap, so the pipe is a wake token, not a queue.
/// The handler used to write the signal number and, on EAGAIN, drain the
/// backlog in the handler itself and retry -- which spent a read loop in
/// async-signal context to preserve a value nothing read.
const wake_token: u8 = 1;

/// Async-signal-safe, non-blocking write of the single wake token.
///
/// EAGAIN needs no recovery: a full pipe means an UNCONSUMED token is already
/// queued, which is precisely the state this write exists to create, and the
/// reader's bitmap swap collects every signal that arrived in the meantime.
fn writeWakeToken() void {
    const wfd = signal_pipe[pipe_write];
    const rc: isize = @bitCast(std.os.linux.write(wfd, &[_]u8{wake_token}, 1));
    if (rc <= 0) return; // pipe full (already awake) or closed fd: lossy, as before
}

// Re-entry guard for the SIGUSR2 backtrace dump: a second USR2 arriving
// mid-dump must be dropped rather than re-enter the write path.
var backtrace_in_progress: std.atomic.Value(bool) = .init(false);

// SIGUSR2: live diagnostic. Dumps the stack of the INTERRUPTED main thread
// (the exact spot hana is stuck in when it freezes) straight to stderr
// (-> ~/hana-crash.log via .xinitrc). Trigger with: kill -USR2 <pid>
//
// Unlike SIGUSR1, no byte is written to the self-pipe: the point is to work
// when the event loop itself is wedged and would never dispatch a pipe byte.
// Using the kernel-provided ucontext makes the trace show the pre-signal
// frame (the hang site), not this handler.
//
// ASYNC-SIGNAL-SAFETY: this handler runs in the signal context, so it only
// performs raw write(2) on stack buffers and reads the interrupted thread's
// own frame chain, bounded to its stack window. It must NOT use locks, the
// allocator, or std.debug symbolization: those re-enter exclusive state the
// interrupted main thread may hold (GPA lock, io lock), which would hang the
// dump exactly when it is most needed. Frames print as raw return addresses;
// resolve them offline with e.g. `addr2line -e hana -f -C`.
fn handleBacktraceRequest(
    sig: std.posix.SIG,
    info: *const std.posix.siginfo_t,
    ctx_ptr: ?*anyopaque,
) callconv(.c) void {
    _ = sig;
    _ = info;
    if (backtrace_in_progress.swap(true, .acq_rel)) return;
    defer backtrace_in_progress.store(false, .release);

    const fd = std.posix.STDERR_FILENO;
    writeLiteral(fd, "hana: SIGUSR2 backtrace of interrupted main thread (raw addresses):\n");

    const opt_ctx: ?std.debug.cpu_context.Native =
        std.debug.cpu_context.fromPosixSignalContext(ctx_ptr);
    if (opt_ctx) |*ctx| {
        writePcLine(fd, 0, ctx.getPc());
        if (builtin.cpu.arch == .x86_64) {
            // Frame-pointer walk over the interrupted thread's stack. Stacks
            // grow down, so every frame pointer is >= the interrupted rsp and
            // the chain strictly increases; bound reads to rsp..rsp+span (the
            // main thread's default 8 MiB stack mapping) so a corrupted chain
            // can never dereference unrelated memory.
            const span: usize = 8 << 20;
            // Each saved frame straddles rbp and rbp+8 (saved rbp then return
            // address); +16 bounds the chain strictly within the span.
            const frame_stride: usize = 16;
            // A real frame pointer is 8-aligned; unaligned pointers are a
            // corrupted chain.
            const frame_alignment: usize = 8;
            const max_depth: usize = 96;
            const lo = ctx.gprs.get(.rsp);
            const hi = lo + span;
            var rbp = ctx.getFp();
            var depth: usize = 0;
            while (rbp >= lo and
                rbp + frame_stride <= hi and
                (rbp & (frame_alignment - 1)) == 0 and
                depth < max_depth)
            {
                const next: usize = @as(*align(8) const usize, @ptrFromInt(rbp)).*;
                const ret: usize = @as(*align(8) const usize, @ptrFromInt(rbp + 8)).*;
                if (!(next > rbp and
                    next + frame_stride <= hi and
                    (next & (frame_alignment - 1)) == 0)) break;
                rbp = next;
                depth += 1;
                writePcLine(fd, depth, ret);
            }
        } else {
            writeLiteral(fd, "  (frame-pointer walk not implemented for this architecture)\n");
        }
    } else {
        writeLiteral(fd, "  (no ucontext available; interrupted frames unrecoverable)\n");
    }
}

// Async-signal-safe literal write: raw write(2), no buffers, no locks.
fn writeLiteral(fd: std.posix.fd_t, s: []const u8) void {
    _ = std.os.linux.write(fd, s.ptr, s.len);
}

/// Async-signal-safe single-frame line: "  #<depth> 0x<16 hex>\n". Purely
/// stack-local formatting plus one raw write(2); symbols are resolved offline.
fn writePcLine(fd: std.posix.fd_t, depth: usize, addr: usize) void {
    const hex = "0123456789abcdef";
    var buf: [8 + 16 + 1]u8 = undefined;
    buf[0] = ' ';
    buf[1] = ' ';
    buf[2] = '#';
    buf[3] = @as(u8, '0') + @as(u8, @intCast(depth / 10));
    buf[4] = @as(u8, '0') + @as(u8, @intCast(depth % 10));
    buf[5] = ' ';
    buf[6] = '0';
    buf[7] = 'x';
    var rest = addr;
    var i = buf.len - 2;
    while (i >= 8) : (i -= 1) {
        buf[i] = hex[rest & 0xf];
        rest >>= 4;
    }
    buf[buf.len - 1] = '\n';
    _ = std.os.linux.write(fd, &buf, buf.len);
}

// Replaces the default SIGUSR2 disposition with the live backtrace dump.
fn setupBacktraceHandler() void {
    const sa: std.posix.Sigaction = .{
        .handler = .{ .sigaction = handleBacktraceRequest },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.SIGINFO | std.posix.SA.RESTART | std.posix.SA.ONSTACK,
    };
    std.posix.sigaction(std.posix.SIG.USR2, &sa, null);
}

/// The signals that get the self-pipe handler. SIGCHLD is reaped in
/// dispatchSignal; the rest control the event loop.
const handled_signals = [_]std.posix.SIG{
    std.posix.SIG.HUP,
    std.posix.SIG.TERM,
    std.posix.SIG.INT,
    std.posix.SIG.CHLD,
    std.posix.SIG.USR1,
};

/// What `setup` installs, as DATA, with no side effects.
///
/// Naming the policy as a value separates the question from the effects:
/// `plan` is pure and testable, `install` is the only thing that touches
/// process state -- which is what lets a test assert the table directly,
/// since installing the real dispositions from a test binary would clobber
/// the runner's own SIGINT/SIGTERM handling.
pub const Plan = struct {
    /// Signals that get the self-pipe handler, in install order.
    handled: []const std.posix.SIG,
    /// The one signal ignored outright. Kept out of `handled` because its
    /// disposition is SIG_IGN, not a handler.
    ignored: std.posix.SIG,
    // Order matters and is why this is not reordered: the alternate stack MUST
    // be installed before any ONSTACK handler is armed, because the backtrace
    // handler runs on it, and without one it would run on the (possibly
    // corrupted) stack it exists to diagnose.
};

/// The disposition policy, as pure data. No signal is touched, no fd opened.
pub fn plan() Plan {
    return .{
        .handled = &handled_signals,
        .ignored = std.posix.SIG.PIPE,
    };
}

/// Creates the signal self-pipe and installs the dispositions `plan` describes.
pub fn setup() !void {
    signal_pipe = try spawn.makePipe();
    setSignalWriteFd(signal_pipe[pipe_write]);
    try install(plan());
}

/// Performs the side effects `p` describes: the only function here that mutates
/// process-wide signal state.
fn install(p: Plan) !void {
    const sa: std.posix.Sigaction = .{
        .handler = .{ .handler = signalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };

    for (p.handled) |sig| {
        std.posix.sigaction(sig, &sa, null);
    }

    // SIGPIPE: ignore it. The spawn engine deliberately writes into an
    // early-closed pipe end (forkIntermediate's tag_pid handoff); with the
    // default disposition a raced write would SIGPIPE-kill the WM instead of
    // failing the write.
    std.posix.sigaction(p.ignored, &.{
        .handler = .{ .handler = @ptrFromInt(1) }, // SIG_IGN
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);

    // The backtrace handler arms SA.ONSTACK, but no alternate stack was
    // ever installed -- without one the handler would run on the (possibly
    // corrupted) interrupted stack it exists to diagnose. Install it before
    // arming any ONSTACK handler.
    const ss: std.posix.stack_t = .{
        .sp = &alt_stack_mem,
        .flags = 0,
        .size = alt_stack_mem.len,
    };
    try std.posix.sigaltstack(&ss, null);

    setupBacktraceHandler();
}

// Closes both ends of the signal pipe.
pub fn deinit() void {
    setSignalWriteFd(-1);
    for (&signal_pipe) |*fd| {
        if (fd.* == -1) continue;
        _ = std.os.linux.close(fd.*);
        fd.* = -1;
    }
}

/// Read end of the signal self-pipe, for the event loop's poll fd array.
pub fn readFd() std.posix.fd_t {
    return signal_pipe[pipe_read];
}

// Dispatches one signal from the pending-signals bitmap. The self-pipe byte
// is only a wake token; the signal number comes from the bitmap, not the
// byte.
fn dispatchSignal(pending_sig: u8) void {
    switch (@as(std.posix.SIG, @enumFromInt(pending_sig))) {
        .HUP => reload(),
        // Unconditional in-place re-exec of the current binary (no change
        // check). Dispatch runs on the event loop, NOT in the signal
        // handler, so flag work is safe.
        .USR1 => requestReexec(),
        .TERM, .INT => quit(),
        // SIGCHLD: a spawned child has exited (or, now that hana is a
        // subreaper, an orphaned grandchild of one has re-parented to us).
        // Reap it with WNOHANG, then immediately drain the spawn pipes so
        // registerSpawn fires without waiting for the next XCB event batch.
        .CHLD => {
            spawn.reapPendingChildren();
            spawn.drainPendingSpawns();
        },
        else => {},
    }
}

/// Drains the non-blocking signal pipe and dispatches each pending signal.
///
/// The pipe is read purely as a wake token (see `wake_token`); signal state
/// lives in `pending_signals`. Reading first, then consuming the bitmap, means a
/// signal that arrives after the swap re-arms the pipe, so the next poll drains
/// and consumes it.
///
/// std.os.linux.read returns usize; a kernel error wraps a negative value into
/// a huge unsigned number an unsigned comparison would never catch. Bitcast to
/// isize and stop on any non-positive result (error, EOF, or empty).
pub fn drainAndDispatch(fd: std.posix.fd_t) void {
    var buf: [drain_buf_size]u8 = undefined;
    while (true) {
        const rc: isize = @bitCast(std.os.linux.read(fd, &buf, buf.len));
        if (rc <= 0) break; // 0 = EOF on write-end close, negative = error/EAGAIN
    }
    var bits = pending_signals.swap(0, .acq_rel);
    while (bits != 0) {
        const bit: u6 = @intCast(@ctz(bits));
        bits &= bits - 1;
        dispatchSignal(@intCast(bit));
    }
}
