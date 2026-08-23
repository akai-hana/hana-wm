//! Threading primitives (D6 split from utils.zig). xcb-free.
//!
//! Zig 0.16 removed std.Thread.Mutex/Condition (replaced by std.Io.Mutex,
//! which requires threading an std.Io handle through every lock/unlock call
//! site, too invasive for the small, self-contained locking bar.zig and
//! bar.zig needs). This is a minimal handle-free substitute.
//! between both instead of each defining its own copy.

const std = @import("std");
const time = @import("time.zig");

/// Blocking mutex backed by pthread_mutex_t; `.{}` is safe (= PTHREAD_MUTEX_INITIALIZER).
pub const Mutex = struct {
    inner: std.c.pthread_mutex_t = .{},
    pub fn lock(m: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&m.inner);
    }
    pub fn unlock(m: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&m.inner);
    }
};

/// Condition variable backed by pthread_cond_t; `.{}` is safe (= PTHREAD_COND_INITIALIZER).
/// Call `initMonotonic()` on any instance that will use `timedWait`.
pub const Condition = struct {
    inner: std.c.pthread_cond_t = .{},

    // pthread_condattr_t is not exposed by std.c on this Zig version, so it's
    // pulled in from the system header directly. Using the real type (rather
    // than a hand-sized opaque buffer) keeps the stack allocation exactly as
    // large as libc's definition, no silent corruption if a libc ever
    // grows the type.
    const pthread = @cImport(@cInclude("pthread.h"));

    /// Re-initialises this condition variable to use CLOCK_MONOTONIC as its
    /// clock, so that a subsequent `timedWait` can use a monotonic deadline
    /// (immune to wall-clock adjustments). Must be called once before any
    /// `timedWait` call; safe to call on a freshly zero-initialised instance,
    /// and safe to call again later (e.g. on every config reload) as long as
    /// no thread is currently blocked in `wait`/`timedWait` on it.
    pub fn initMonotonic(cv: *Condition) void {
        var attr: pthread.pthread_condattr_t = undefined;
        if (pthread.pthread_condattr_init(&attr) != 0) return;
        defer _ = pthread.pthread_condattr_destroy(&attr);
        _ = pthread.pthread_condattr_setclock(&attr, @intFromEnum(std.os.linux.CLOCK.MONOTONIC));
        _ = pthread.pthread_cond_init(@ptrCast(&cv.inner), &attr);
    }

    /// Waits up to `timeout_ns` nanoseconds; returns error.Timeout on expiry.
    /// Uses a CLOCK_MONOTONIC absolute deadline; requires that `initMonotonic()`
    /// was called on this instance at startup.
    pub fn timedWait(c: *Condition, m: *Mutex, timeout_ns: u64) error{Timeout}!void {
        const deadline_ns = time.monotonicNs() +| timeout_ns;
        var ts: std.os.linux.timespec = .{
            .sec = @intCast(deadline_ns / std.time.ns_per_s),
            .nsec = @intCast(deadline_ns % std.time.ns_per_s),
        };
        const rc = std.c.pthread_cond_timedwait(&c.inner, &m.inner, @ptrCast(&ts));
        if (rc == std.posix.E.TIMEDOUT) return error.Timeout;
    }

    pub fn signal(c: *Condition) void {
        _ = std.c.pthread_cond_signal(&c.inner);
    }
};

/// Owns the mutex/condvar/quit-flag/thread quartet used by the bar's
/// background threads (clock). `start` spawns `f` with `self` as
/// its only argument; `stop` signals and joins.
pub const CondThread = struct {
    mutex: Mutex = .{},
    cond: Condition = .{},
    quit: bool = false,
    thread: ?std.Thread = null,

    pub fn start(self: *CondThread, comptime f: anytype, args: anytype) !void {
        self.cond.initMonotonic();
        self.quit = false;
        self.thread = try std.Thread.spawn(.{}, f, args);
    }

    pub fn stop(self: *CondThread) void {
        self.mutex.lock();
        self.quit = true;
        self.cond.signal();
        self.mutex.unlock();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }
};
