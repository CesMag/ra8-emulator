//! The FPU corpus image (RA8EMU-143): tests/fixtures/fpu/fp_basic.elf runs
//! single- and double-precision add, sub, mul, div, sqrt and fma on the Zig
//! core and leaves each result beside the FPSCR it set. The expected words
//! come from the DDI0553 FPAdd/FPSub/FPMul/FPDiv/FPSqrt/FPMulAdd pseudocode
//! (round to nearest even, default NaN, IOC/DZC/IXC), not from the core.
const std = @import("std");
const ra8 = @import("ra8");
const memmap = ra8.chip.core.memmap;
const boot = ra8.chip.core.cpu.boot;
const elf = ra8.board.image.elf;
const Store = ra8.chip.core.cpu.memory.store.Store;
const Guest = ra8.chip.core.cpu.memory.guest.Guest;

const image_bytes = @embedFile("../../../fixtures/fpu/fp_basic.elf");
const results = memmap.sram_base + 0x100;
/// FPSCR words hold only the cumulative flags, so compare those bits.
const flag_mask: u32 = 0x9F;

/// Five f32 pairs then five f64 pairs, six ops each: an f32 op stores
/// result, FPSCR; an f64 op stores low word, high word, FPSCR. A done
/// marker closes the run.
const expected = [_]u32{
    0x4080_0000, 0x0000_0000, 0xC000_0000, 0x0000_0000,
    0x4040_0000, 0x0000_0000, 0x3EAA_AAAB, 0x0000_0010,
    0x3F80_0000, 0x0000_0000, 0x4080_0000, 0x0000_0000,
    0x3E99_999A, 0x0000_0010, 0xBDCC_CCCD, 0x0000_0000,
    0x3CA3_D70B, 0x0000_0010, 0x3F00_0000, 0x0000_0000,
    0x3EA1_E89B, 0x0000_0010, 0x3DF5_C290, 0x0000_0010,
    0xC2F5_E979, 0x0000_0000, 0xC2F7_E979, 0x0000_0000,
    0xC276_E979, 0x0000_0000, 0xC376_E979, 0x0000_0000,
    0x7FC0_0000, 0x0000_0001, 0xC339_2F1B, 0x0000_0010,
    0x4049_0FDB, 0x0000_0000, 0x4049_0FDB, 0x0000_0000,
    0x0000_0000, 0x0000_0000, 0x7F80_0000, 0x0000_0002,
    0x3FE2_DFC5, 0x0000_0010, 0x4049_0FDB, 0x0000_0000,
    0x3F80_0000, 0x0000_0000, 0xC040_0000, 0x0000_0000,
    0xC000_0000, 0x0000_0000, 0xBF00_0000, 0x0000_0000,
    0x7FC0_0000, 0x0000_0001, 0xC040_0000, 0x0000_0000,
    0x0000_0000, 0x4010_0000, 0x0000_0000, 0x0000_0000,
    0xC000_0000, 0x0000_0000, 0x0000_0000, 0x4008_0000,
    0x0000_0000, 0x5555_5555, 0x3FD5_5555, 0x0000_0010,
    0x0000_0000, 0x3FF0_0000, 0x0000_0000, 0x0000_0000,
    0x4010_0000, 0x0000_0000, 0x3333_3334, 0x3FD3_3333,
    0x0000_0010, 0x9999_999A, 0xBFB9_9999, 0x0000_0000,
    0x47AE_147C, 0x3F94_7AE1, 0x0000_0010, 0x0000_0000,
    0x3FE0_0000, 0x0000_0000, 0x6248_490F, 0x3FD4_3D13,
    0x0000_0010, 0xEB85_1EB9, 0x3FBE_B851, 0x0000_0010,
    0x1A9F_BE77, 0xC05E_BD2F, 0x0000_0000, 0x1A9F_BE77,
    0xC05E_FD2F, 0x0000_0000, 0x1A9F_BE77, 0xC04E_DD2F,
    0x0000_0000, 0x1A9F_BE77, 0xC06E_DD2F, 0x0000_0000,
    0x0000_0000, 0x7FF8_0000, 0x0000_0001, 0x53F7_CED9,
    0xC067_25E3, 0x0000_0010, 0x5444_2D18, 0x4009_21FB,
    0x0000_0000, 0x5444_2D18, 0x4009_21FB, 0x0000_0000,
    0x0000_0000, 0x0000_0000, 0x0000_0000, 0x0000_0000,
    0x7FF0_0000, 0x0000_0002, 0x91B4_EF6A, 0x3FFC_5BF8,
    0x0000_0010, 0x5444_2D18, 0x4009_21FB, 0x0000_0000,
    0x0000_0000, 0x3FF0_0000, 0x0000_0000, 0x0000_0000,
    0xC008_0000, 0x0000_0000, 0x0000_0000, 0xC000_0000,
    0x0000_0000, 0x0000_0000, 0xBFE0_0000, 0x0000_0000,
    0x0000_0000, 0x7FF8_0000, 0x0000_0001, 0x0000_0000,
    0xC008_0000, 0x0000_0000, 0x0F9C_0DE5,
};

fn isFpscr(index: usize) bool {
    if (index >= 150) return false;
    if (index < 60) return index % 2 == 1;
    return (index - 60) % 3 == 2;
}

test "the FPU corpus image runs bit-exact on the Zig core" {
    const image = try elf.Image.init(image_bytes);
    var store = try Store.init(null);
    defer store.deinit();
    const core: Guest = .{ .store = &store };
    var segment_index: u16 = 0;
    while (segment_index < image.segmentCount()) : (segment_index += 1) {
        const segment = image.loadSegment(segment_index) orelse continue;
        try core.write(segment.paddr, segment.bytes);
    }
    var output: [128]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&output);
    var retired: u64 = 0;
    const vector_base = image.vectorBase() orelse return error.MissingVectorTable;
    var periph = ra8.chip.periph.registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    const status = try boot.start(&stream, .zig, core, &periph, vector_base, 20_000, &retired, .{});
    try std.testing.expectEqual(@as(u8, 0), status);
    for (expected, 0..) |want, index| {
        const got = try core.readWord(results + @as(u32, @intCast(index)) * 4);
        const mask: u32 = if (isFpscr(index)) flag_mask else 0xFFFF_FFFF;
        std.testing.expectEqual(want, got & mask) catch |err| {
            std.debug.print("word {d}: want 0x{X:0>8} got 0x{X:0>8}\n", .{ index, want, got });
            return err;
        };
    }
}
