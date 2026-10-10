//! Tests for src/chip/periph/npu/vela_quant.zig: the scale, activation and
//! stride registers a Vela program sets.
const std = @import("std");
const ra8 = @import("ra8");
const vela = ra8.chip.periph.npu_vela;
const quant = vela.quant;

test "the cmd0 activation and accumulator sets each keep their parameter" {
    var state = quant.State{};
    try std.testing.expectEqual(quant.Outcome.applied, quant.applyCmd0(&state, 0x124, 1));
    try std.testing.expectEqual(quant.Outcome.applied, quant.applyCmd0(&state, 0x126, 0xFF80));
    try std.testing.expectEqual(quant.Outcome.applied, quant.applyCmd0(&state, 0x127, 0x007F));
    try std.testing.expectEqual(quant.Outcome.applied, quant.applyCmd0(&state, 0x129, 4));
    try std.testing.expectEqual(@as(u16, 1), state.acc_format);
    try std.testing.expectEqual(@as(u16, 0xFF80), state.activation_min);
    try std.testing.expectEqual(@as(u16, 0x007F), state.activation_max);
    try std.testing.expectEqual(@as(u16, 4), state.scale_region);
}

test "a cmd1 scale takes the scale from the payload and the shift from the parameter" {
    var state = quant.State{};
    try std.testing.expectEqual(quant.Outcome.applied, quant.applyCmd1(&state, 0x024, 31, 0x4000_0000));
    try std.testing.expectEqual(quant.Outcome.applied, quant.applyCmd1(&state, 0x025, 20, 0x1234_5678));
    try std.testing.expectEqual(quant.Scale{ .scale = 0x4000_0000, .shift = 31 }, state.ofm_scale);
    try std.testing.expectEqual(quant.Scale{ .scale = 0x1234_5678, .shift = 20 }, state.opa_scale);
}

test "strides land per feature map and per axis" {
    var state = quant.State{};
    _ = quant.applyCmd1(&state, 0x004, 0, 16);
    _ = quant.applyCmd1(&state, 0x005, 0, 128);
    _ = quant.applyCmd1(&state, 0x016, 0, 1024);
    _ = quant.applyCmd1(&state, 0x084, 0, 8);
    try std.testing.expectEqual(quant.Stride{ .x = 16, .y = 128, .c = 0 }, state.ifm_stride);
    try std.testing.expectEqual(@as(u32, 1024), state.ofm_stride.c);
    try std.testing.expectEqual(@as(u32, 8), state.ifm2_stride.x);
}

test "a set this file does not keep is reported and changes nothing" {
    var state = quant.State{};
    try std.testing.expectEqual(quant.Outcome.not_modelled, quant.applyCmd0(&state, 0x120, 2));
    try std.testing.expectEqual(quant.Outcome.not_modelled, quant.applyCmd1(&state, 0x000, 0, 9));
    try std.testing.expectEqual(quant.State{}, state);
}

test "the runner keeps the scale and stride registers the program set" {
    const Memory = struct {
        pub fn read(_: *@This(), _: u32, _: []u8) error{Refused}!void {}
        pub fn write(_: *@This(), _: u32, _: []const u8) error{Refused}!void {}
    };
    var memory = Memory{};
    const regions: vela.dma.Regions = @splat(0);
    // OFM_SCALE shift 12 + payload, IFM_STRIDE_X + payload, ACTIVATION_MAX, STOP.
    const words = [_]u32{ 0x000C_4024, 0x0000_7FFF, 0x0000_4004, 0x0000_0020, 0x007F_0127, 0x0000_0000 };
    const result = try vela.runner.run(&memory, &regions, &words);
    try std.testing.expectEqual(quant.Scale{ .scale = 0x7FFF, .shift = 12 }, result.quant.ofm_scale);
    try std.testing.expectEqual(@as(u32, 0x20), result.quant.ifm_stride.x);
    try std.testing.expectEqual(@as(u16, 0x7F), result.quant.activation_max);
}
