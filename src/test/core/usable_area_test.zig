//! The usable-area claim arithmetic and the occupancy contract it encodes.
//!
//! These are the tests that make the rule non-reversible by accident: the claim
//! table and the pure solver are what a future "fullscreen means no work
//! area" shortcut would be tempted to bypass, so the cases that a shortcut
//! would get wrong are stated explicitly here rather than left to a reviewer
//! to imagine.

const std = @import("std");
const testing = std.testing;
const usable_area = @import("usable_area");

test "no claims yields the full screen" {
    // The state a bar that is off (or hidden for fullscreen) leaves behind.
    // A fullscreen window that has hidden the bar is therefore NOT recorded
    // as occupying anything: the claim was released, and the area is whole.
    const wa = usable_area.workAreaFrom(1920, 1080);
    try testing.expectEqual(@as(i16, 0), wa.x);
    try testing.expectEqual(@as(i16, 0), wa.y);
    try testing.expectEqual(@as(u16, 1920), wa.width);
    try testing.expectEqual(@as(u16, 1080), wa.height);
}

test "a top claim insets only the top edge" {
    // A bar at the top with a 30px claim: height shrinks by exactly 30, and
    // the other three edges are untouched. The asymmetry is the point -- a
    // top claim that also moved x/y would be a second, invisible claim.
    usable_area.setClaim(.top, 30);
    defer usable_area.releaseClaim();
    const wa = usable_area.workAreaFrom(1920, 1080);
    try testing.expectEqual(@as(i16, 0), wa.x);
    try testing.expectEqual(@as(i16, 30), wa.y);
    try testing.expectEqual(@as(u16, 1920), wa.width);
    try testing.expectEqual(@as(u16, 1050), wa.height);
}

test "bottom claim insets the bottom edge and leaves y at zero" {
    usable_area.setClaim(.bottom, 30);
    defer usable_area.releaseClaim();
    const wa = usable_area.workAreaFrom(1920, 1080);
    try testing.expectEqual(@as(i16, 0), wa.y);
    try testing.expectEqual(@as(u16, 1050), wa.height);
    try testing.expectEqual(@as(u16, 1920), wa.width);
}

test "a claim larger than the screen saturates to zero, never wraps" {
    // A bar taller than the display is a degenerate config, and the two
    // candidate answers are "nowhere to place" and "1920 - 0 - 1080 wrapped
    // to a huge rect". The second is the bug this pins: it hands layouts a
    // rect whose far edge is off the end of the display, and every subsequent
    // geometry add silently moves windows somewhere no one can reach.
    usable_area.setClaim(.top, 2000);
    defer usable_area.releaseClaim();
    const wa = usable_area.workAreaFrom(1920, 1080);
    try testing.expectEqual(@as(u16, 0), wa.height);
    try testing.expectEqual(@as(u16, 1920), wa.width);
}

test "a claim exactly the screen height is zero, not negative-and-wrapped" {
    // The boundary case. `-|` saturates at 0, so this lands on the same
    // zero-sized answer as an oversized claim rather than underflowing.
    usable_area.setClaim(.top, 1080);
    defer usable_area.releaseClaim();
    const wa = usable_area.workAreaFrom(1920, 1080);
    try testing.expectEqual(@as(u16, 0), wa.height);
}

test "zero-px claim is a no-op, distinct from no claim at all" {
    // A mapped-but-zero-height bar publishes a zero claim. It must leave the
    // area whole, which is also what a released claim leaves -- the two are
    // indistinguishable in the area, and that is intended: a surface that
    // occupies no pixels constrains nothing.
    usable_area.setClaim(.top, 0);
    defer usable_area.releaseClaim();
    const wa = usable_area.workAreaFrom(1920, 1080);
    try testing.expectEqual(@as(u16, 1080), wa.height);
}

test "releasing the claim restores the full screen" {
    // The path a fullscreen window actually takes: the bar unmaps, releases,
    // and the area goes whole again with no fullscreen input anywhere. If
    // this test needed a fullscreen fact to pass, occupancy would have two
    // encodings -- which is exactly what the rule ruled out.
    {
        usable_area.setClaim(.top, 30);
        defer usable_area.releaseClaim();
        try testing.expectEqual(@as(u16, 1050), usable_area.workAreaFrom(1920, 1080).height);
    }
    try testing.expectEqual(@as(u16, 1080), usable_area.workAreaFrom(1920, 1080).height);
}

test "a foreign dock claim insets its edge, keyed per window" {
    // F-80: a dock's _NET_WM_STRUT_PARTIAL publishes into the same ledger
    // arithmetic, so a peer's placement avoids it exactly like it avoids the
    // bar. Keyed by window id: exactly the claimed edge moves.
    try testing.expect(usable_area.setDockClaim(0x500001, 0, 0, 40, 0));
    defer _ = usable_area.releaseDockClaim(0x500001);
    const wa = usable_area.workAreaFrom(1920, 1080);
    try testing.expectEqual(@as(i16, 40), wa.y);
    try testing.expectEqual(@as(u16, 1920), wa.width);
    try testing.expectEqual(@as(u16, 1040), wa.height);

    const c = usable_area.dockClaimOf(0x500001).?;
    try testing.expectEqual(@as(u16, 40), c.top);
}

test "bar and dock claims on the same edge sum" {
    // Two claimants, one edge: a 30px bar plus a 40px dock must inset 70,
    // not max() them, not replace the first with the second. This is the case
    // that would break the day two slots existed -- now they do.
    usable_area.setClaim(.top, 30);
    defer usable_area.releaseClaim();
    defer _ = usable_area.releaseDockClaim(0x500002);
    try testing.expect(usable_area.setDockClaim(0x500002, 0, 0, 40, 0));
    try testing.expectEqual(@as(i16, 70), usable_area.workAreaFrom(1920, 1080).y);
    // Releasing the dock leaves the bar's claim standing.
    try testing.expect(usable_area.releaseDockClaim(0x500002));
    try testing.expectEqual(@as(i16, 30), usable_area.workAreaFrom(1920, 1080).y);
}

test "dock claims on different edges inset independently" {
    defer _ = usable_area.releaseDockClaim(0x500003);
    defer _ = usable_area.releaseDockClaim(0x500004);
    try testing.expect(usable_area.setDockClaim(0x500003, 100, 0, 0, 0));
    try testing.expect(usable_area.setDockClaim(0x500004, 0, 0, 40, 0));
    const wa = usable_area.workAreaFrom(1920, 1080);
    try testing.expectEqual(@as(i16, 100), wa.x);
    try testing.expectEqual(@as(i16, 40), wa.y);
    try testing.expectEqual(@as(u16, 1820), wa.width);
    try testing.expectEqual(@as(u16, 1040), wa.height);
}

test "dock claim writes report change: republish same is no-op, release idempotent" {
    // The property-notify refresh re-reads a dock's strut on every rewrite;
    // identical values must not claim a ledger change (no forced re-tile),
    // and a vanished window's double-release must not lie about change.
    defer _ = usable_area.releaseDockClaim(0x500005);
    try testing.expect(usable_area.setDockClaim(0x500005, 0, 0, 24, 0));
    try testing.expect(!usable_area.setDockClaim(0x500005, 0, 0, 24, 0));
    try testing.expect(usable_area.setDockClaim(0x500005, 0, 0, 48, 0));
    try testing.expect(usable_area.releaseDockClaim(0x500005));
    try testing.expect(!usable_area.releaseDockClaim(0x500005));
    try testing.expect(usable_area.dockClaimOf(0x500005) == null);
}
