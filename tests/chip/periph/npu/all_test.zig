//! The NPU share of the test root: every test file under tests/chip/periph/npu/,
//! pulled in by tests/all.zig.
test {
    _ = @import("cmd_test.zig");
    _ = @import("npu_test.zig");
    _ = @import("vela_test.zig");
    _ = @import("vela_regs_test.zig");
    _ = @import("vela_dma_test.zig");
    _ = @import("vela_run_test.zig");
    _ = @import("vela_hook_test.zig");
    _ = @import("vela_fm_test.zig");
    _ = @import("vela_quant_test.zig");
    _ = @import("vela_addr_test.zig");
    _ = @import("vela_bias_test.zig");
    _ = @import("vela_weights_test.zig");
    _ = @import("vela_order_test.zig");
    _ = @import("vela_round_test.zig");
    _ = @import("vela_conv_test.zig");
    _ = @import("vela_convop_test.zig");
    _ = @import("vela_mul_test.zig");
    _ = @import("vela_addsub_test.zig");
    _ = @import("vela_avgpool_test.zig");
    _ = @import("vela_minmax_test.zig");
    _ = @import("vela_pool_test.zig");
}
