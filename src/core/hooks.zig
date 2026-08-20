//! Plugin interface for optional subsystems.
//! Defines the function-pointer table that optional modules implement to hook into the core event loop and lifecycle.

const std = @import("std");
const core = @import("core");
const xcb = core.xcb;

pub const Plugin = struct {
    // Lifecycle.
    init: ?*const fn () anyerror!void = null,
    deinit: ?*const fn () void = null,
    reload: ?*const fn () void = null,

    // XCB event handlers.
    on_expose: ?*const fn (*const xcb.xcb_expose_event_t) void = null,
    on_property_notify: ?*const fn (*const xcb.xcb_property_notify_event_t) void = null,
    on_button_press: ?*const fn (*const xcb.xcb_button_press_event_t) void = null,

    // Event-loop integration.
    post_batch: ?*const fn () anyerror!void = null,
    // Return true to signal the event loop to stop iterating.
    iteration_end: ?*const fn () bool = null,

    // Poll integration.
    poll_timeout_ms: ?*const fn () i32 = null,
    on_poll_wakeup: ?*const fn () void = null,
};
