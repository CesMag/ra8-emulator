//! The NPU share of the test root: every test file under tests/chip/periph/npu/,
//! pulled in by tests/all.zig.
test {
    _ = @import("cmd_test.zig");
    _ = @import("npu_test.zig");
    _ = @import("vela/vela_test.zig");
    _ = @import("vela/regs_test.zig");
    _ = @import("vela/dma_test.zig");
    _ = @import("vela/run_test.zig");
    _ = @import("vela/hook_test.zig");
    _ = @import("vela/fm_test.zig");
    _ = @import("vela/quant_test.zig");
    _ = @import("vela/addr_test.zig");
    _ = @import("vela/bias_test.zig");
    _ = @import("vela/weights_test.zig");
    _ = @import("vela/order_test.zig");
    _ = @import("vela/round_test.zig");
    _ = @import("vela/conv_test.zig");
    _ = @import("vela/convop_test.zig");
    _ = @import("vela/mul_test.zig");
    _ = @import("vela/addsub_test.zig");
    _ = @import("vela/avgpool_test.zig");
    _ = @import("vela/minmax_test.zig");
    _ = @import("vela/pool_test.zig");
}
