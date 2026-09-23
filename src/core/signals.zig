//! Signal self-pipe and dispatch.
//! Routes POSIX signals through a self-pipe so the event loop can dispatch them safely.

const std = @import("std");
const builtin = @import("builtin");

const utils = @import("utils");
const spawn = @import("spawn");
const restart = @import("restart");

// End indices of the self-pipe: signal handlers write to pipe_write; the
// event loop polls pipe_read.
const pipe_read = 0;
const pipe_write = 1;

/// Bytes drained per read from the self-pipe: draining a burst in one syscall
/// rather than one per byte keeps the signal handler and the event loop cheap.
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
    const bit: u6 = @intCast(@intFromEnum(signo));
    _ = pending_signals.fetchOr(@as(u64, 1) << bit, .release);
    const byte: u8 = @intCast(@intFromEnum(signo));
    writeSignalByte(byte);
}

/// Async-signal-safe, non-blocking write of one signal byte to the self-pipe,
/// with full-pipe recovery. When the pipe is full (EAGAIN) the queued backlog
/// is drained and the write retried so THIS byte lands; the drained bytes carry
/// no state (the handler records signal state in `pending_signals`), so
/// discarding them only coalesces wakeups.
fn writeSignalByte(byte: u8) void {
    const rfd = signal_pipe[pipe_read];
    const wfd = signal_pipe[pipe_write];
    while (true) {
        const rc: isize = @bitCast(std.os.linux.write(wfd, &[_]u8{byte}, 1));
        if (rc > 0) return; // landed
        const err: usize = @intCast(-rc);
        if (err == @intFromEnum(std.posix.E.AGAIN) and rfd >= 0) {
            var buf: [drain_buf_size]u8 = undefined;
            while (@as(isize, @bitCast(std.os.linux.read(rfd, &buf, buf.len))) > 0) {}
            continue;
        }
        return; // other error or closed fd: give up (lossy, as before)
    }
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

/// Creates the signal self-pipe and installs handlers for SIGHUP/SIGTERM/SIGINT/SIGCHLD.
pub fn setup() !void {
    signal_pipe = try utils.makePipe();
    utils.setSignalWriteFd(signal_pipe[pipe_write]);

    const sa: std.posix.Sigaction = .{
        .handler = .{ .handler = signalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };

    // SIGCHLD is reaped in dispatchSignal; the rest control the event loop.
    inline for (.{
        std.posix.SIG.HUP,
        std.posix.SIG.TERM,
        std.posix.SIG.INT,
        std.posix.SIG.CHLD,
        std.posix.SIG.USR1,
    }) |sig| {
        std.posix.sigaction(sig, &sa, null);
    }

    // SIGPIPE: ignore it. The spawn engine deliberately writes into an
    // early-closed pipe end (forkIntermediate's tag_pid handoff); with the
    // default disposition a raced write would SIGPIPE-kill the WM instead of
    // failing the write.
    std.posix.sigaction(std.posix.SIG.PIPE, &.{
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
    utils.setSignalWriteFd(-1);
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

// Dispatches a single pending signal (a byte value from the pipe, one per
// set bit in the pending-signals bitmap).
fn dispatchSignal(pending_sig: u8) void {
    switch (@as(std.posix.SIG, @enumFromInt(pending_sig))) {
        .HUP => utils.reload(),
        // Unconditional in-place re-exec of the current binary (no change
        // check). Dispatch runs on the event loop, NOT in the signal
        // handler, so flag work is safe.
        .USR1 => restart.requestReexec(),
        .TERM, .INT => utils.quit(),
        // SIGCHLD: an intermediate double-fork child has exited.
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
/// The pipe is read purely as a wake token; signal state lives in
/// `pending_signals`. Reading first, then consuming the bitmap, means a signal
/// that arrives after the swap re-arms the pipe (writeSignalByte always lands
/// once it has drained the backlog), so the next poll drains and consumes it.
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
