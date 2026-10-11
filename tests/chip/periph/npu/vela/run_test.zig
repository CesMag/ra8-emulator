//! Tests for src/chip/periph/npu/vela/run.zig: a Vela stream run end to end
//! as far as register state and DMA go.
const std = @import("std");
const ra8 = @import("ra8");
const vela = ra8.chip.periph.npu.vela;

/// A flat 4 KiB memory at bus address 0x1000 that refuses everything else.
const Memory = struct {
    bytes: [4096]u8 = @splat(0),

    const base: u32 = 0x1000;

    fn slot(self: *Memory, address: u32, len: usize) error{Refused}![]u8 {
        if (address < base or address - base + len > self.bytes.len) return error.Refused;
        return self.bytes[address - base ..][0..len];
    }

    pub fn read(self: *Memory, address: u32, into: []u8) error{Refused}!void {
        @memcpy(into, try self.slot(address, into.len));
    }

    pub fn write(self: *Memory, address: u32, bytes: []const u8) error{Refused}!void {
        @memcpy(try self.slot(address, bytes.len), bytes);
    }
};

const regions: vela.dma.Regions = .{ 0x1000, 0x1800, 0, 0, 0, 0, 0, 0 };

/// Region 0 to region 1, 0x40 bytes from offset 0x10 to offset 0x20.
const dma_program = [_]u32{
    0x0000_0130, // DMA0_SRC_REGION region 0
    0x0001_0131, // DMA0_DST_REGION region 1
    0x0000_4030, 0x0000_0010, // DMA0_SRC
    0x0000_4031, 0x0000_0020, // DMA0_DST
    0x0000_4032, 0x0000_0040, // DMA0_LEN
    0x0000_0010, // DMA_START
    0x0000_0011, // DMA_WAIT
};

test "a DMA-only program moves its bytes between regions and stops" {
    var memory = Memory{};
    for (memory.bytes[0x10..0x50], 0..) |*b, i| b.* = @truncate(i + 1);
    const result = try vela.run.run(&memory, &regions, &(dma_program ++ [_]u32{0x0000_0000}));
    try std.testing.expectEqual(@as(u64, 0x40), result.moved);
    try std.testing.expectEqualSlices(u8, memory.bytes[0x10..0x50], memory.bytes[0x820..0x860]);
    try std.testing.expectEqual(@as(u64, 0x40), result.state.dma0.len);
    try std.testing.expectEqual(@as(usize, 2), result.summary.register_sets);
}

test "a program with an operator stops before claiming it ran" {
    var memory = Memory{};
    const words = dma_program ++ [_]u32{ 0x0000_0003, 0x0000_0000 }; // DEPTHWISE, STOP
    try std.testing.expectError(error.OperatorNotModelled, vela.run.run(&memory, &regions, &words));
}

test "a malformed stream is refused before anything moves" {
    var memory = Memory{};
    @memset(memory.bytes[0..0x100], 0x5A);
    try std.testing.expectError(error.NoStop, vela.run.run(&memory, &regions, &dma_program));
    try std.testing.expectEqual(@as(u8, 0), memory.bytes[0x820]);
}

test "a DMA the memory refuses surfaces as Refused" {
    var memory = Memory{};
    const far: vela.dma.Regions = .{ 0x1000, 0x9000, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectError(error.Refused, vela.run.run(&memory, &far, &(dma_program ++ [_]u32{0x0000_0000})));
}

/// A real Vela 3.12.0 stream (ethos-u55-256): TFLite MAXIMUM, int8 1x4x4x8,
/// both inputs and the output at scale 0.05, zero point -3. IFM at region 1
/// offset 0x00, IFM2 at 0x80, and the OFM written in place over the IFM.
/// The 324 bytes after the 32-byte driver header, as Vela emitted them.
const vela_max = [_]u32{
    0x00004024, 0x00000001, 0x0001010F, 0x00004000, 0x00000000, 0x00004001,
    0x00000000, 0x00004002, 0x00000000, 0x00004003, 0x00000000, 0x0003010B,
    0x0003010C, 0x0003010A, 0x00070104, 0x00004006, 0x00000001, 0x00004005,
    0x00000020, 0x00004004, 0x00000008, 0xFFFD0109, 0x00010105, 0x00000107,
    0x0001011F, 0x00004010, 0x00000000, 0x00004011, 0x00000000, 0x00004012,
    0x00000000, 0x00004013, 0x00000000, 0x0003011B, 0x0003011C, 0x0003011A,
    0x00030112, 0x00030111, 0x00070113, 0x00004016, 0x00000001, 0x00004015,
    0x00000020, 0x00004014, 0x00000008, 0xFFFD0118, 0x00010114, 0x00000125,
    0xFF800126, 0x007F0127, 0x00030116, 0x00030115, 0x00070117, 0x002E010D,
    0x002E012D, 0x000A018D, 0x00000124, 0x0001018F, 0x00004080, 0x00000080,
    0x00004081, 0x00000000, 0x00004082, 0x00000000, 0x00004083, 0x00000000,
    0x0003018B, 0x0003018C, 0x0003018A, 0x00004086, 0x00000001, 0x00004085,
    0x00000020, 0x00004084, 0x00000008, 0xFFFD0189, 0x00010185, 0x00000180,
    0x0000012F, 0x00040006, 0xFFFF0000,
};

test "a Vela-compiled MAXIMUM runs to its STOP and writes the larger of each pair" {
    var memory = Memory{};
    var a: [128]i8 = undefined;
    var b: [128]i8 = undefined;
    for (&a, &b, 0..) |*x, *y, i| {
        x.* = @bitCast(@as(u8, @truncate(i * 37 + 11)));
        y.* = @bitCast(@as(u8, @truncate(i * 91 + 200)));
    }
    @memcpy(memory.bytes[0x800..0x880], std.mem.asBytes(&a));
    @memcpy(memory.bytes[0x880..0x900], std.mem.asBytes(&b));
    const result = try vela.run.run(&memory, &regions, &vela_max);
    try std.testing.expectEqual(@as(u64, 128), result.elements);
    for (a, b, 0..) |x, y, i| {
        try std.testing.expectEqual(@max(x, y), @as(i8, @bitCast(memory.bytes[0x800 + i])));
    }
}

/// A real Vela 3.12.0 stream (ethos-u55-256): TFLite MAX_POOL_2D, 2x2 kernel,
/// stride 2, VALID, int8 1x4x4x8 in and 1x2x2x8 out, scale 0.05 and zero
/// point -3 on both. IFM at region 1 offset 0x00, OFM at 0x80. The 256
/// bytes after the 32-byte driver header, as Vela emitted them.
const vela_maxpool = [_]u32{
    0x0001010F, 0x00004000, 0x00000000, 0x00004001, 0x00000000, 0x00004002,
    0x00000000, 0x00004003, 0x00000000, 0x0003010B, 0x0003010C, 0x0003010A,
    0x00070104, 0x00004006, 0x00000001, 0x00004005, 0x00000020, 0x00004004,
    0x00000008, 0xFFFD0109, 0x00010105, 0x00000107, 0x00000100, 0x00000101,
    0x00000103, 0x00000102, 0x0001011F, 0x00004010, 0x00000080, 0x00004011,
    0x00000000, 0x00004012, 0x00000000, 0x00004013, 0x00000000, 0x0001011B,
    0x0001011C, 0x0001011A, 0x00010112, 0x00010111, 0x00070113, 0x00004016,
    0x00000001, 0x00004015, 0x00000010, 0x00004014, 0x00000008, 0xFFFD0118,
    0x00010114, 0x00010121, 0x00010120, 0x00030122, 0x00000125, 0xFF800126,
    0x007F0127, 0x00010116, 0x00010115, 0x00070117, 0x000A010D, 0x001E012D,
    0x00000124, 0x0000012F, 0x00000005, 0xFFFF0000,
};

test "a Vela-compiled MAX_POOL_2D writes the largest of each 2x2 window" {
    var memory = Memory{};
    var x: [4][4][8]i8 = undefined;
    for (0..4) |h| for (0..4) |w| for (0..8) |c| {
        x[h][w][c] = @bitCast(@as(u8, @truncate(h * 71 + w * 29 + c * 13 + 5)));
    };
    @memcpy(memory.bytes[0x800..0x880], std.mem.asBytes(&x));
    const result = try vela.run.run(&memory, &regions, &vela_maxpool);
    try std.testing.expectEqual(@as(u64, 32), result.elements);
    for (0..2) |h| for (0..2) |w| for (0..8) |c| {
        const want = @max(@max(x[2 * h][2 * w][c], x[2 * h][2 * w + 1][c]), @max(x[2 * h + 1][2 * w][c], x[2 * h + 1][2 * w + 1][c]));
        const got: i8 = @bitCast(memory.bytes[0x880 + h * 16 + w * 8 + c]);
        try std.testing.expectEqual(want, got);
    };
}

/// A real Vela 3.12.0 stream (ethos-u55-256): a per-channel int8 1x1
/// CONV_2D, 8 channels in and 6 out over 4x4, IFM zero point -5, OFM zero
/// point 7. It DMAs flash 0x40 (0xA0 bytes: the scale records, then the
/// weight stream) from region 0 to region 1 offset 0xE0, then runs the
/// conv with the IFM at region 1 offset 0x00 and the OFM at 0x80. The 336
/// bytes after the 32-byte driver header, as Vela emitted them.
const vela_conv = [_]u32{
    0x00000130, 0x00004030, 0x00000040, 0x00010131, 0x00004031, 0x000000E0,
    0x00004032, 0x000000A0, 0x00000010, 0x0001010F, 0x00004000, 0x00000000,
    0x00004001, 0x00000000, 0x00004002, 0x00000000, 0x00004003, 0x00000000,
    0x0003010B, 0x0003010C, 0x0003010A, 0x00070104, 0x00004006, 0x00000001,
    0x00004005, 0x00000020, 0x00004004, 0x00000008, 0xFFFB0109, 0x00010105,
    0x00000107, 0x00000100, 0x00000101, 0x00000103, 0x00000102, 0x0001011F,
    0x00004010, 0x00000080, 0x00004011, 0x00000000, 0x00004012, 0x00000000,
    0x00004013, 0x00000000, 0x0003011B, 0x0003011C, 0x0003011A, 0x00030112,
    0x00030111, 0x00050113, 0x00004016, 0x00000001, 0x00004015, 0x00000018,
    0x00004014, 0x00000006, 0x00070118, 0x00010114, 0x00000121, 0x00000120,
    0x00040122, 0x00010128, 0x00004020, 0x00000120, 0x00004021, 0x00000060,
    0x00010129, 0x00004022, 0x000000E0, 0x00004023, 0x00000040, 0x00000125,
    0xFF800126, 0x007F0127, 0x00030116, 0x00030115, 0x00070117, 0x000A010D,
    0x001E012D, 0x00000124, 0x0000012F, 0x00000011, 0x00000002, 0xFFFF0000,
};

fn hexBytes(comptime hex: []const u8) [hex.len / 2]u8 {
    var out: [hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}

/// The 0xA0 flash bytes the conv's DMA reads, from Vela's flash tensor.
const conv_flash = hexBytes("d605000000e823385327d10a000000df8793742870f6ffffff255fee73264405000000335b42432626fbffffffb6555d61" ++
    "28f7000000000175c74e2600000000680150f11d2c98615f4f1fff6e4e1e5eed5cccbbab7bcb8a4a2a9a491908d8b75717" ++
    "571656d80030d8f7f8a6c00b4afca60780113f1eed57008003710d42a47e6b53c98183d437004070830d9652fb7a000002" ++
    "00fffff33f80ffffffffffffff");
const conv_ifm = hexBytes("cd47e21bf735d896cb211e7bbeec729c33756a2d64b2412c017e58b57b5adf3248b8c2aff674e3d76cf08f2743f07280" ++
    "5dc24cf82642651b23ee8db09d489cafb939cfff2e0dfbe271b34babfa24cac6ab83c3b1266b8636e71476e69e5163c3" ++
    "1522a18385251e781935f793d61730d1a06bba84e8832898cfd638612d10ba29");
/// TFLite Micro's double-rounding output for that IFM (tflite-runtime
/// agrees on every byte).
const conv_ofm = hexBytes("e116e403f4134a0a800cf28b3aece3db0cc1d4146ca0f63abf197f1217ede6db7f043680170c50e71780c31c384906" ++
    "3aec0530d8fa49db230732248ebe2f4bf7017f272fcee2e78b1e047f00eb7fef0a70e302f4eef54fcd00561f1e8020fd14");

test "a Vela-compiled int8 CONV_2D runs its DMA and conv and writes TFLite Micro's output" {
    var memory = Memory{};
    @memcpy(memory.bytes[0x40..0xE0], &conv_flash);
    @memcpy(memory.bytes[0x800..0x880], &conv_ifm);
    const result = try vela.run.run(&memory, &regions, &vela_conv);
    try std.testing.expectEqual(@as(u64, 0xA0), result.moved);
    try std.testing.expectEqual(@as(u64, 96), result.elements);
    try std.testing.expectEqualSlices(u8, &conv_ofm, memory.bytes[0x880..0x8E0]);
}

test "a conv whose scale records run short is refused" {
    var memory = Memory{};
    @memcpy(memory.bytes[0x40..0xE0], &conv_flash);
    var words = vela_conv;
    words[70] = 0x00000032; // SCALE_LENGTH 0x40 -> 0x32: five records
    try std.testing.expectError(error.BadScales, vela.run.run(&memory, &regions, &words));
}
