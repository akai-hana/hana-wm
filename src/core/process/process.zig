//! Process lifecycle: module-level atomics, the in-place exec coordinator, and
//! the signal self-pipe (POSIX signals routed through a self-pipe so the event
//! loop dispatches without handler reentrancy). Config reloads (SIGHUP) are
//! separate from re-exec.

const std = @import("std");

const log = std.log.scoped(.process);

const builtin = @import("builtin");

const spawn = @import("spawn");

/// Set to false by SIGTERM/SIGINT to break the main event loop.
pub var running = std.atomic.Value(bool).init(true);

/// Set by SIGHUP or the `reload_config` keybinding; consumed by `consumeReload`.
var should_reload = std.atomic.Value(bool).init(false);

/// Write end of the signal self-pipe (owned by `setup`), registered via
/// `setSignalWriteFd` so `reload()` can wake the event loop out of poll.
var signal_write_fd: std.posix.fd_t = -1;

/// Byte `reload()`/`wake()` write to poke the event loop; pure wake token, the
/// drain dispatches from the real-signal bitmap so no value collides.
const wake_byte: u8 = 0xff;

/// Registers the signal-pipe write end; pass -1 to unregister (teardown).
pub fn setSignalWriteFd(fd: std.posix.fd_t) void {
    signal_write_fd = fd;
}

/// Writes the wake byte if the pipe is registered. Lossy by design: the event
/// loop polls its flags every iteration, so a lost byte costs one poll timeout.
fn writeWakeByte() void {
    if (signal_write_fd >= 0)
        _ = std.os.linux.write(signal_write_fd, &[_]u8{wake_byte}, 1);
}

/// Gracefully stop the main event loop.
pub fn quit() void {
    running.store(false, .release);
}

/// Signals the event loop to reload the user config. Safe from any thread: the
/// wake byte is a plain write, not a signal (lossy write: see `writeWakeByte`).
pub fn reload() void {
    if (!should_reload.swap(true, .acq_rel)) writeWakeByte();
}

/// Writes the wake byte without touching any flag: `requestReexec`'s separate
/// flag is noticed immediately instead of waiting for an unrelated signal.
pub fn wake() void {
    writeWakeByte();
}

/// Atomically consumes the reload flag; true exactly once per request.
pub fn consumeReload() bool {
    return should_reload.swap(false, .acq_rel);
}

// libc bindings for execv/setenv (no stdlib wrappers exist). execv (not
// execvp) is deliberate: we hand it the absolute self path (no PATH lookup),
// and the variadic form inherits the environ carrying DISPLAY and HANA_RESTORE.
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
});

/// c_allocator-owned, NUL-terminated copy of `src`, or die: the X connection
/// is already closed, so ending the session is all that is left.
fn mustDupeZ(src: []const u8, what: []const u8) [:0]const u8 {
    return std.heap.c_allocator.dupeZ(u8, src) catch {
        log.err("restart: out of memory copying {s}", .{what});
        std.process.exit(1);
    };
}

/// Null-terminated `/proc/self/exe` path for re-exec; c_allocator-owned,
/// process-lifetime: never freed.
var exec_path_z: ?[:0]const u8 = null;

/// Re-exec request flag; set by `requestReexec`, consumed by `consumeReexec`.
var should_reexec = std.atomic.Value(bool).init(false);

/// Resolves the binary to exec on re-exec (readLink of `/proc/self/exe`),
/// one-shot at startup before any request can arrive.
pub fn init() void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.os.linux.readlinkat(std.os.linux.AT.FDCWD, "/proc/self/exe", &buf, buf.len);
    // readlinkat returns exactly `buf.len` (errno SUCCESS) when truncated --
    // no NUL -- so a full buffer must count as unresolvable: execv must never
    // receive a cut-off path.
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

/// Unconditional re-exec (`reload_hana` / SIGUSR1): re-exec the current
/// binary, skipping any change check.
pub fn requestReexec() void {
    should_reexec.store(true, .release);
    wake();
}

/// Atomic, mirrors consumeReload: true exactly once per request. Consumed by
/// the event loop AFTER consumeReload (events.run checks reload first).
pub fn consumeReexec() bool {
    return should_reexec.swap(false, .acq_rel);
}

/// The running image's sentinel-terminated path for `execv`. Null when
/// re-exec was never armed. This form avoids re-duplicating a held string.
fn selfPathZ() ?[:0]const u8 {
    return exec_path_z;
}

/// Env vars carrying the re-exec hand-off. Writer (`execNext`) and reader
/// (boot, via `restorePathFromEnv`) must agree on these names exactly: a typo
/// on the reading side silently boots the successor as a COLD boot that adopts
/// nothing, with no error anywhere.
pub const restore_env = "HANA_RESTORE";
pub const config_dir_env = "HANA_CONFIG_DIR";

/// The restore path a previous instance handed over, or null on cold boot.
/// Borrowed from the environ -- do not free or retain past adoption.
pub fn restorePathFromEnv() ?[*:0]const u8 {
    return std.c.getenv(restore_env);
}

/// The complete re-exec hand-off: naming the set makes "what crosses the
/// transition" one declaration that call sites and tests cannot get wrong.
pub const Handoff = struct {
    /// Sentinel-terminated (`selfPathZ()`); this process's own image.
    self_path: [:0]const u8,
    /// The session state file; the only copy is made inside the call needing it.
    restore_path: []const u8,
    /// Frozen last-good config dir, or null when no user config was ever loaded.
    config_snapshot: ?[:0]const u8 = null,
};

/// The hand-off for this process, or null when re-exec was never armed.
/// `config_snapshot` is passed in rather than fetched here: importing config
/// from `core/process` would invert the dependency for no gain.
pub fn currentHandoff(restore_path: []const u8, config_snapshot: ?[:0]const u8) ?Handoff {
    const self_path = selfPathZ() orelse return null;
    return .{
        .self_path = self_path,
        .restore_path = restore_path,
        .config_snapshot = config_snapshot,
    };
}

/// Execs `self_path` IN PLACE, inheriting environ/DISPLAY. Never returns.
/// MUST run only after the X connection is closed: a live inherited fd would
/// keep the old client's root SubstructureRedirect grab alive, and the server
/// would reject the fresh connection with BadAccess.
///
/// Deliberately NO fork: the pid/parent identity must survive so the startx
/// session chain (xinit -> ... -> this process) stays unbroken -- a
/// fork-then-exit would make xinit tear down Xorg mid-hand-off.
///
/// The restore path crosses via `restore_env`: execv inherits environ, and
/// Zig 0.16's `main() !void` cannot read argv, so the environment is the one
/// channel a fresh boot can see.
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
    // Only reachable when exec failed; the X connection is already closed.
    log.err("restart: execv failed", .{});
    std.process.exit(1);
}

// End indices of the self-pipe: signal handlers write to pipe_write; the
// event loop polls pipe_read.
const pipe_read = 0;
const pipe_write = 1;

/// Read size per syscall; the pipe holds only ignored wake tokens, so this
/// just clears a coalesced burst in one call.
const drain_buf_size: usize = 16;

var signal_pipe: [2]std.posix.fd_t = .{ -1, -1 };

// Alternate-signal-stack backing for the SA.ONSTACK SIGUSR2 handler: 64 KiB
// (~8x SIGSTKSZ) so it never tops out; static so no allocator runs in signal
// context; align(16) for the ABI-aligned stack pointer the kernel installs.
var alt_stack_mem: [64 * 1024]u8 align(16) = undefined;

// Async-signal-safe pending-signal bitmap. The pipe byte is only a WAKE
// TOKEN: signal STATE must not ride on it (a full pipe can discard a byte), so
// the handler sets a bit and the event loop consumes the whole word -- a
// TERM/INT/reload during a pipe-full burst can never be lost.
var pending_signals: std.atomic.Value(u64) = .init(0);

// Async-signal-safe handler: records the signal and wakes the loop.
fn signalHandler(signo: std.posix.SIG) callconv(.c) void {
    // Clamp past-63 signal numbers rather than panic: a panic in an
    // async-signal handler cannot unwind and would abort the process; a
    // clamped signal still lands in the bitmap and still gets dispatched.
    const bit: u6 = @intCast(@min(@intFromEnum(signo), 63));
    _ = pending_signals.fetchOr(@as(u64, 1) << bit, .release);
    writeWakeToken();
}

/// The self-pipe byte; its VALUE carries nothing -- the pipe is a wake token,
/// not a queue (the reader consumes the whole `pending_signals` bitmap).
const wake_token: u8 = 1;

/// Async-signal-safe, non-blocking write of the wake token. EAGAIN needs no
/// recovery: a full pipe already holds an UNCONSUMED token, the very state
/// this write exists to create; the bitmap swap collects signals in between.
fn writeWakeToken() void {
    const wfd = signal_pipe[pipe_write];
    const rc: isize = @bitCast(std.os.linux.write(wfd, &[_]u8{wake_token}, 1));
    if (rc <= 0) return; // pipe full (already awake) or closed fd: lossy
}

// Re-entry guard: a second USR2 mid-dump must be dropped, not re-entered.
var backtrace_in_progress: std.atomic.Value(bool) = .init(false);

// SIGUSR2: live diagnostic. Dumps the INTERRUPTED main thread's stack (the
// hang site) straight to stderr (-> ~/hana-crash.log via .xinitrc); trigger
// with `kill -USR2 <pid>`. Unlike SIGUSR1 no pipe byte is written: the point
// is to work when the event loop itself is wedged. The kernel ucontext makes
// the trace show the pre-signal frame, not this handler.
//
// ASYNC-SIGNAL-SAFETY: only raw write(2) on stack buffers plus a bounded
// walk of the interrupted thread's own frame chain. It must NOT use locks, the
// allocator, or std.debug symbolization -- those re-enter exclusive state the
// interrupted thread may hold (GPA lock, io lock) and would hang the dump
// exactly when it is most needed. Frames print as raw addresses; resolve
// offline with e.g. `addr2line -e hana -f -C`.
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
            // Frame-pointer walk over the interrupted stack: chains grow
            // strictly upward from rsp, so bounding reads to rsp..rsp+span
            // (the 8 MiB Linux pthread main-stack default, not a measured
            // working set) keeps a corrupted chain off unrelated memory.
            const span: usize = 8 << 20;
            // A saved frame straddles rbp..rbp+8 (saved rbp, return address).
            const frame_stride: usize = 16;
            // Real frame pointers are 8-aligned; unaligned = corrupted chain.
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

/// Async-signal-safe frame line: "  #<depth> 0x<16 hex>\n" via stack-local
/// formatting plus one raw write(2); symbols resolve offline.
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

/// What `setup` installs, as DATA with no side effects. Naming the policy as
/// a value keeps `plan` pure and testable -- a test can assert the table
/// without installing real dispositions that would clobber the runner's own
/// SIGINT/SIGTERM handling.
pub const Plan = struct {
    /// Signals that get the self-pipe handler, in install order.
    handled: []const std.posix.SIG,
    /// The one signal ignored outright (SIG_IGN, not a handler).
    ignored: std.posix.SIG,
    // Order is load-bearing: the alternate stack MUST be installed before any
    // ONSTACK handler is armed -- the backtrace handler runs on it, and
    // without one it would run on the (possibly corrupted) stack it exists
    // to diagnose.
};

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

    // Alternate stack before any ONSTACK handler (see the Plan field note).
    const ss: std.posix.stack_t = .{
        .sp = &alt_stack_mem,
        .flags = 0,
        .size = alt_stack_mem.len,
    };
    try std.posix.sigaltstack(&ss, null);

    setupBacktraceHandler();
}

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

// Dispatches one signal from the pending-signals bitmap (the pipe byte is
// only a wake token; the number comes from the bitmap).
fn dispatchSignal(pending_sig: u8) void {
    switch (@as(std.posix.SIG, @enumFromInt(pending_sig))) {
        .HUP => reload(),
        // Runs on the event loop, NOT in the signal handler, so flag work is safe.
        .USR1 => requestReexec(),
        .TERM, .INT => quit(),
        // SIGCHLD: a child exited (or a subreaper-orphaned grandchild
        // re-parented to us). Reap WNOHANG, then drain the spawn pipes so
        // registerSpawn fires without waiting for the next XCB batch.
        .CHLD => {
            spawn.reapPendingChildren();
            spawn.drainPendingSpawns();
        },
        else => {},
    }
}

/// Drains the non-blocking signal pipe and dispatches each pending signal.
/// Read-then-swap ordering: a signal arriving after the bitmap swap re-arms
/// the pipe, so the next poll drains and consumes it.
///
/// std.os.linux.read returns usize; a kernel error wraps a negative value into
/// a huge unsigned an unsigned comparison would never catch. Bitcast to isize
/// and stop on any non-positive result (error, EOF, or empty).
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
