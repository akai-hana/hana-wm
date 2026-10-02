//! The event loop's deadline policy
//!
//! The loop blocks in poll() forever unless a timer source says otherwise,
//! and turning "several sources may speak" into one number is a POLICY, not
//! arithmetic. It used to live in two files at once: `bar.pollTimeoutMs`
//! reduced over the bar's own modules taking the shortest non-negative value,
//! and then the loop re-applied the same ignore-the-negatives rule at its call
//! site (`if (ms >= 0)`). Both halves had to agree, and neither file could
//! see the other's.
//!
//! `Timers` owns the whole rule once. Core holds the list, the loop asks the
//! one question, and a timer source is a list entry rather than a branch at
//! the call site.

/// One timer source. `null` means "this source wants no wakeup"; a
/// non-negative value is "wake me in this many ms".
///
/// Sources report ABSENCE as null rather than as a negative number, so the
/// distinction between "no timer here" and "a timer in -1 ms" cannot be
/// expressed by accident.
pub const Source = *const fn () ?i32;

/// The loop's registered timer sources, reduced on demand.
///
/// This looks like a list abstraction wrapped around the single entry the loop
/// currently registers (the bar's own deadline), and has been proposed for
/// deletion as such. It is the opposite of redundant: the list IS the policy.
/// The reduce -- consult every source even after one answers, because a later
/// source may want to wake sooner -- is the rule, and a one-entry version could
/// not express it, so the second source would arrive as a branch at the call
/// site, which is the shape this module was created to remove. See
/// timers_test.zig, which exercises the reduce with four sources.
pub const Timers = struct {
    sources: []const Source,

    /// The nearest wakeup across every source, or null when no source wants
    /// one (the loop then blocks until an fd is ready).
    ///
    /// Every source is consulted even once one has answered: a later source
    /// may want to wake sooner, and "sooner" is the whole point. `min` over
    /// the answered ones is the deadline.
    pub fn deadlineMs(self: Timers) ?i32 {
        var nearest: ?i32 = null;
        for (self.sources) |source| {
            const ms = source() orelse continue;
            if (nearest == null or ms < nearest.?) nearest = ms;
        }
        return nearest;
    }
};
