//! ETH peripheral test index.
test {
    _ = @import("agent_test.zig");
    _ = @import("desc_test.zig");
    _ = @import("coma_test.zig");
    _ = @import("tas_test.zig");
    _ = @import("cbs_test.zig");
    _ = @import("dma_test.zig");
    _ = @import("forward_test.zig");
    _ = @import("gateway_test.zig");
    _ = @import("mac_test.zig");
    _ = @import("mode_test.zig");
    _ = @import("open_regs_test.zig");
    _ = @import("line_test.zig");
    _ = @import("queue_test.zig");
    _ = @import("eth_test.zig");
}
