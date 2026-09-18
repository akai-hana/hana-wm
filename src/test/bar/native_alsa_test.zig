//! Test module for the dependency-free ALSA control backend. The pure
//! ABI-size/ioctl-encoding/percent-mapping logic lives as inline tests in
//! native_alsa.zig; importing the module here runs them under `zig build
//! test`. The live ioctl read/write path is verified against the probing
//! machine's card (see the module doc) and cannot run in unit tests.

const std = @import("std");
const native_alsa = @import("native_alsa");

test {
    _ = native_alsa;
    _ = std;
}
