//! Tests for the run policy still under src/chip/periph/time: it leaves for the
//! session in RA8EMU-1047, so it never passes through src/chip.
test {
    _ = @import("pacer_test.zig");
    _ = @import("pacing_test.zig");
    _ = @import("speed_test.zig");
    _ = @import("soak_test.zig");
    _ = @import("soak_fault_test.zig");
    _ = @import("soak_watch_test.zig");
    _ = @import("soak_threads_test.zig");
}
