//! Reload decision tests (P1-25): the pure accept/reject table behind
//! `reload.handleConfigReload`, extracted so it is testable without
//! `core.getState()` or an X connection. The ordering half of the reload
//! contract (detectChanges pre-swap, buildKeybinds/regrab post-swap so the
//! resolver stamps the rev the swap just bumped) stays documented on
//! `handleConfigReload` and covered end-to-end by harness scenarios
//! S13/S23; these tests pin the decision itself: a broken load keeps the old
//! config, a missing user config soft-rejects (the embedded fallback is
//! boot-only), and only a user-sourced load reaches the swap.

const std = @import("std");
const testing = std.testing;
const reload = @import("reload");

test "decide: a failed load always keeps the old config" {
    // Broken TOML / IO error / too-many-files: the load never produced a
    // config, so the source out-param is whatever the failed load left
    // behind -- the decision must not depend on it. The live config stays,
    // nothing is freed here (the load path's own errdefers already did), and
    // the keybind regrab is skipped. The caller reports the error once.
    try testing.expectEqual(reload.Decision.fail_keep_old, reload.decide(false, .user));
    try testing.expectEqual(reload.Decision.fail_keep_old, reload.decide(false, .fallback));
}

test "decide: a successful load without a user config soft-rejects" {
    // loadConfigDefault falls back to the embedded config when no user file
    // exists. Boot keeps that fallback; on RELOAD it must not silently
    // displace a live user config. Not an error: the caller logs, the
    // short-lived load is freed, nothing is rebuilt.
    try testing.expectEqual(reload.Decision.reject_keep_old, reload.decide(true, .fallback));
}

test "decide: a successful user-sourced load applies" {
    // The only arm that swaps: detectChanges pre-swap, replaceOwnedConfig,
    // then buildKeybinds / refreshSnapshot / reloadBorders / regrab
    // post-swap (see the ordering doc on handleConfigReload).
    try testing.expectEqual(reload.Decision.apply_new, reload.decide(true, .user));
}

test "decide: the decision table is pinned" {
    // A new or renamed arm must be a deliberate edit here AND at the
    // exhaustive switch in handleConfigReload: both fail loudly otherwise,
    // so no decision row can be added without a test naming it.
    const fields = @typeInfo(reload.Decision).@"enum".fields;
    try testing.expectEqual(@as(usize, 3), fields.len);
    try testing.expectEqualStrings("fail_keep_old", fields[0].name);
    try testing.expectEqualStrings("reject_keep_old", fields[1].name);
    try testing.expectEqualStrings("apply_new", fields[2].name);
}
