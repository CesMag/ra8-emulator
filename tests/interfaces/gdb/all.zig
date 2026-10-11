//! Tests for src/interfaces/gdb, the GDB remote serial protocol server.
test {
    _ = @import("rsp/packet_test.zig");
    _ = @import("rsp/features_test.zig");
    _ = @import("rsp/dispatch_test.zig");
    _ = @import("rsp/units_test.zig");
}
