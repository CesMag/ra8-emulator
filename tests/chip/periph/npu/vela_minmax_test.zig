//! Tests for src/chip/periph/npu/vela_minmax.zig: elementwise MIN and MAX.
const std = @import("std");
const ra8 = @import("ra8");
const vela = ra8.chip.periph.npu_vela;
const minmax = vela.minmax;

const Memory = struct {
    bytes: [0x400]u8 = @splat(0),
    pub fn read(self: *@This(), at: u32, out: []u8) error{Refused}!void {
        if (at + out.len > self.bytes.len) return error.Refused;
        @memcpy(out, self.bytes[at..][0..out.len]);
    }
    pub fn write(self: *@This(), at: u32, data: []const u8) error{Refused}!void {
        if (at + data.len > self.bytes.len) return error.Refused;
        @memcpy(self.bytes[at..][0..data.len], data);
    }
};

/// A 1x2x4 int8 NHWC elementwise setup: IFM at 0x000, IFM2 at 0x100,
/// OFM at 0x200, all in region 0, clamp -128..127.
fn inputs() minmax.Inputs {
    var maps = vela.fm.State{};
    for ([_]*vela.fm.Map{ &maps.ifm, &maps.ifm2, &maps.ofm }) |map| {
        map.* = .{ .width0_m1 = 1, .height0_m1 = 0, .height1_m1 = 0, .depth_m1 = 3, .precision = 1 };
    }
    maps.ofm_width_m1 = 1;
    maps.ofm_height_m1 = 0;
    const stride = vela.quant.Stride{ .x = 4, .y = 8, .c = 1 };
    const q = vela.quant.State{
        .activation_min = 0xFF80,
        .activation_max = 0x007F,
        .ifm_stride = stride,
        .ifm2_stride = stride,
        .ofm_stride = stride,
    };
    var bases: @FieldType(minmax.Inputs, "bases") = .{};
    bases.ifm = .{ 0x000, 0, 0, 0 };
    bases.ifm2 = .{ 0x100, 0, 0, 0 };
    bases.ofm = .{ 0x200, 0, 0, 0 };
    return .{ .bases = bases, .maps = maps, .quant = q };
}

const a = [8]i8{ -5, 3, 100, -128, 0, 7, -1, 127 };
const b = [8]i8{ 2, -3, 50, -127, 0, 9, -2, -128 };

fn fill(memory: *Memory) void {
    for (a, 0..) |v, i| memory.bytes[i] = @bitCast(v);
    for (b, 0..) |v, i| memory.bytes[0x100 + i] = @bitCast(v);
}

test "MIN writes the smaller signed element of each pair" {
    var memory = Memory{};
    fill(&memory);
    const regions: vela.dma.Regions = @splat(0);
    try std.testing.expectEqual(@as(u64, 8), try minmax.run(&memory, &regions, minmax.mode_min, inputs()));
    for (0..8) |i| try std.testing.expectEqual(@min(a[i], b[i]), @as(i8, @bitCast(memory.bytes[0x200 + i])));
}

test "MAX writes the larger element and honours the region base" {
    var memory = Memory{};
    for (a, 0..) |v, i| memory.bytes[0x40 + i] = @bitCast(v);
    for (b, 0..) |v, i| memory.bytes[0x140 + i] = @bitCast(v);
    var regions: vela.dma.Regions = @splat(0);
    regions[2] = 0x40;
    var setup = inputs();
    setup.maps.ifm.region = 2;
    setup.maps.ifm2.region = 2;
    _ = try minmax.run(&memory, &regions, minmax.mode_max, setup);
    for (0..8) |i| try std.testing.expectEqual(@max(a[i], b[i]), @as(i8, @bitCast(memory.bytes[0x200 + i])));
}

test "the activation clamp bounds the result" {
    try std.testing.expectEqual(@as(i32, 10), minmax.combine(minmax.mode_max, 3, 90, -10, 10));
    try std.testing.expectEqual(@as(i32, -10), minmax.combine(minmax.mode_min, -50, 4, -10, 10));
    try std.testing.expectEqual(@as(i32, 4), minmax.combine(minmax.mode_min, 7, 4, -10, 10));
}

test "cases the TRM leaves open are refused, not guessed" {
    var memory = Memory{};
    const regions: vela.dma.Regions = @splat(0);
    var mixed = inputs();
    mixed.maps.ifm2.zero_point = 5;
    try std.testing.expectError(error.OperatorNotModelled, minmax.run(&memory, &regions, minmax.mode_min, mixed));
    var lut = inputs();
    lut.quant.activation = 0x10;
    try std.testing.expectError(error.OperatorNotModelled, minmax.run(&memory, &regions, minmax.mode_max, lut));
    try std.testing.expectError(error.OperatorNotModelled, minmax.run(&memory, &regions, 1, inputs()));
}

test "the runner executes an elementwise MAX and counts its elements" {
    var memory = Memory{};
    fill(&memory);
    const regions: vela.dma.Regions = @splat(0);
    // Shapes, precision, strides, bases, clamp, then ELEMENTWISE mode 4 and STOP.
    const words = [_]u32{
        0x0001_010A, 0x0003_0104, 0x0001_0105, 0x0001_018A, 0x0001_0185,
        0x0001_011A, 0x0001_0111, 0x0003_0113, 0x0001_0114, 0xFF80_0126,
        0x007F_0127, 0x0000_4004, 0x0000_0004, 0x0000_4005, 0x0000_0008,
        0x0000_4084, 0x0000_0004, 0x0000_4085, 0x0000_0008, 0x0000_4014,
        0x0000_0004, 0x0000_4015, 0x0000_0008, 0x0000_4080, 0x0000_0100,
        0x0000_4010, 0x0000_0200, 0x0004_0006, 0x0000_0000,
    };
    const result = try vela.runner.run(&memory, &regions, &words);
    try std.testing.expectEqual(@as(u64, 8), result.elements);
    for (0..8) |i| try std.testing.expectEqual(@max(a[i], b[i]), @as(i8, @bitCast(memory.bytes[0x200 + i])));
}

test "a scalar IFM2 is compared against every IFM element" {
    var memory = Memory{};
    fill(&memory);
    const regions: vela.dma.Regions = @splat(0);
    var setup = inputs();
    setup.maps.ifm2_broadcast = minmax.broadcast_scalar;
    setup.maps.ifm2_scalar = @bitCast(@as(i16, -2));
    _ = try minmax.run(&memory, &regions, minmax.mode_max, setup);
    for (0..8) |i| try std.testing.expectEqual(@max(a[i], -2), @as(i8, @bitCast(memory.bytes[0x200 + i])));
}

test "broadcasting W and C reuses IFM2 element (0, 0, 0)" {
    var memory = Memory{};
    fill(&memory);
    const regions: vela.dma.Regions = @splat(0);
    var setup = inputs();
    setup.maps.ifm2_broadcast = minmax.broadcast_w | minmax.broadcast_c;
    _ = try minmax.run(&memory, &regions, minmax.mode_min, setup);
    for (0..8) |i| try std.testing.expectEqual(@min(a[i], b[0]), @as(i8, @bitCast(memory.bytes[0x200 + i])));
}

test "broadcasting C alone keeps IFM2's x and repeats its channel 0" {
    var memory = Memory{};
    fill(&memory);
    const regions: vela.dma.Regions = @splat(0);
    var setup = inputs();
    setup.maps.ifm2_broadcast = minmax.broadcast_c;
    _ = try minmax.run(&memory, &regions, minmax.mode_max, setup);
    // IFM2 x stride is 4, so column 1 reads b[4].
    for (0..8) |i| try std.testing.expectEqual(@max(a[i], b[(i / 4) * 4]), @as(i8, @bitCast(memory.bytes[0x200 + i])));
}
