//! Tests for src/chip/periph/npu/vela_regs.zig: what each cmd1 does to the
//! NPU's address and length registers.
const std = @import("std");
const ra8 = @import("ra8");
const regs = ra8.chip.periph.npu.vela_regs;

fn cmd1(code: u10, param: u16) u32 {
    return @as(u32, code) | 0x4000 | (@as(u32, param) << 16);
}

test "each feature-map tile base lands in its own slot" {
    var state = regs.State{};
    try std.testing.expectEqual(regs.Outcome.applied, regs.apply(&state, cmd1(0x002, 0), 0x2200_0100));
    try std.testing.expectEqual(regs.Outcome.applied, regs.apply(&state, cmd1(0x013, 0), 0x2200_0200));
    try std.testing.expectEqual(regs.Outcome.applied, regs.apply(&state, cmd1(0x080, 0), 0x2200_0300));
    try std.testing.expectEqual(@as(u64, 0x2200_0100), state.ifm[2]);
    try std.testing.expectEqual(@as(u64, 0x2200_0200), state.ofm[3]);
    try std.testing.expectEqual(@as(u64, 0x2200_0300), state.ifm2[0]);
    try std.testing.expectEqual(@as(u64, 0), state.ifm[0]);
}

test "an address takes its top bits from the command's parameter" {
    var state = regs.State{};
    _ = regs.apply(&state, cmd1(0x020, 0x00AB), 0x1234_5678);
    try std.testing.expectEqual(@as(u64, 0xAB_1234_5678), state.weight_base);
}

test "weights, scales and the DMA registers each keep their value" {
    var state = regs.State{};
    _ = regs.apply(&state, cmd1(0x021, 0), 640);
    _ = regs.apply(&state, cmd1(0x022, 0), 0x0200_4000);
    _ = regs.apply(&state, cmd1(0x023, 0), 80);
    _ = regs.apply(&state, cmd1(0x030, 0), 0x0200_0000);
    _ = regs.apply(&state, cmd1(0x031, 0), 0x2200_8000);
    _ = regs.apply(&state, cmd1(0x032, 0), 4096);
    _ = regs.apply(&state, cmd1(0x033, 0), 16);
    _ = regs.apply(&state, cmd1(0x034, 0), 32);
    try std.testing.expectEqual(@as(u64, 640), state.weight_length);
    try std.testing.expectEqual(@as(u64, 0x0200_4000), state.scale_base);
    try std.testing.expectEqual(@as(u64, 80), state.scale_length);
    try std.testing.expectEqual(regs.Dma{ .src = 0x0200_0000, .dst = 0x2200_8000, .len = 4096, .skip0 = 16, .skip1 = 32 }, state.dma0);
}

test "a cmd1 this model does not keep yet is reported, not dropped silently" {
    var state = regs.State{};
    // NPU_SET_IFM_STRIDE_X (0x004).
    try std.testing.expectEqual(regs.Outcome.not_modelled, regs.apply(&state, cmd1(0x004, 0), 1));
    try std.testing.expectEqual(regs.State{}, state);
}
