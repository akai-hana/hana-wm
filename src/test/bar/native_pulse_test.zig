//! Test module for the runtime-dlopen PulseAudio backend. The pure
//! buffer-mapping/offset-guard/cvolume logic lives as inline tests in
//! native_pulse.zig; importing the module here runs them under `zig build
//! test`. Attach/read/commit need libpulse.so.0 and a live daemon, so they
//! are runtime-verified on real machines instead.

const std = @import("std");
const native_pulse = @import("native_pulse");

test {
    _ = native_pulse;
    _ = std;
}
