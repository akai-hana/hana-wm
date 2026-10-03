//! Event loop deadline policy: aggregates active timer sources to compute the
//! next poll timeout; centralizes the min-non-negative rule. No allocations.

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
