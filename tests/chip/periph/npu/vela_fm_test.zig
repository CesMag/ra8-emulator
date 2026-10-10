//! Tests for src/chip/periph/npu/vela_fm.zig: the feature-map registers a
//! Vela program sets with cmd0 commands.
const std = @import("std");
const ra8 = @import("ra8");
const vela = ra8.chip.periph.npu_vela;
const fm = vela.fm;

test "IFM, OFM and IFM2 registers each land in their own map" {
    var state = fm.State{};
    try std.testing.expectEqual(fm.Outcome.applied, fm.apply(&state, 0x104, 15));
    try std.testing.expectEqual(fm.Outcome.applied, fm.apply(&state, 0x109, 0xFF80));
    try std.testing.expectEqual(fm.Outcome.applied, fm.apply(&state, 0x11F, 2));
    try std.testing.expectEqual(fm.Outcome.applied, fm.apply(&state, 0x18F, 3));
    try std.testing.expectEqual(@as(u16, 15), state.ifm.depth_m1);
    try std.testing.expectEqual(@as(u16, 0xFF80), state.ifm.zero_point);
    try std.testing.expectEqual(@as(u16, 2), state.ofm.region);
    try std.testing.expectEqual(@as(u16, 3), state.ifm2.region);
}

test "shapes add the one back to every _m1 field" {
    var state = fm.State{};
    _ = fm.apply(&state, 0x10A, 7); // IFM_WIDTH0_M1
    _ = fm.apply(&state, 0x10B, 3); // IFM_HEIGHT0_M1
    _ = fm.apply(&state, 0x104, 15); // IFM_DEPTH_M1
    _ = fm.apply(&state, 0x111, 9); // OFM_WIDTH_M1
    _ = fm.apply(&state, 0x112, 4); // OFM_HEIGHT_M1
    _ = fm.apply(&state, 0x113, 31); // OFM_DEPTH_M1
    try std.testing.expectEqual(fm.Shape{ .height = 4, .width = 8, .depth = 16 }, fm.tileShape(state.ifm));
    try std.testing.expectEqual(fm.Shape{ .height = 5, .width = 10, .depth = 32 }, state.ofmShape());
}

test "the IFM padding is kept per side" {
    var state = fm.State{};
    _ = fm.apply(&state, 0x100, 1);
    _ = fm.apply(&state, 0x101, 2);
    _ = fm.apply(&state, 0x102, 3);
    _ = fm.apply(&state, 0x103, 4);
    try std.testing.expectEqual(fm.Pad{ .top = 1, .left = 2, .right = 3, .bottom = 4 }, state.ifm_pad);
}

test "a set this file does not keep is reported and changes nothing" {
    var state = fm.State{};
    // DMA0_SRC_REGION (0x130) is not a feature-map register.
    try std.testing.expectEqual(fm.Outcome.not_modelled, fm.apply(&state, 0x130, 1));
    try std.testing.expectEqual(fm.State{}, state);
}

test "the runner keeps the feature-map registers the program set" {
    const Memory = struct {
        pub fn read(_: *@This(), _: u32, _: []u8) error{Refused}!void {}
        pub fn write(_: *@This(), _: u32, _: []const u8) error{Refused}!void {}
    };
    var memory = Memory{};
    const regions: vela.dma.Regions = @splat(0);
    const words = [_]u32{ 0x0007_010A, 0x001F_0113, 0x0001_011F, 0x0000_0000 };
    const result = try vela.runner.run(&memory, &regions, &words);
    try std.testing.expectEqual(@as(u16, 7), result.maps.ifm.width0_m1);
    try std.testing.expectEqual(@as(u16, 31), result.maps.ofm.depth_m1);
    try std.testing.expectEqual(@as(u16, 1), result.maps.ofm.region);
}
