//! Tests for the run policy under src/session/run (RA8EMU-1047).
test {
    _ = @import("pacer_test.zig");
    _ = @import("pacing_test.zig");
    _ = @import("speed_test.zig");
    _ = @import("soak/soak_test.zig");
    _ = @import("soak/fault_test.zig");
    _ = @import("soak/watch_test.zig");
    _ = @import("soak/threads_test.zig");
}
