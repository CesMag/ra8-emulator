//! Tests for src/chip/periph/npu/vela.zig: splitting a Vela command stream
//! into commands and payloads, and counting what it asks for.
const std = @import("std");
const ra8 = @import("ra8");
const vela = ra8.chip.periph.npu_vela;

/// cmd1 NPU_SET_IFM_BASE0 (0x000) with its payload, the way Vela emits it.
const set_ifm_base0 = [_]u32{ 0x0000_4000, 0x0000_1000 };
/// cmd1 NPU_SET_DMA0_SRC (0x030) and NPU_SET_DMA0_LEN (0x032).
const set_dma = [_]u32{ 0x0000_4030, 0x0000_2000, 0x0000_4032, 0x0000_0100 };

test "a program of register writes, a DMA and a conv walks to its STOP" {
    const words = set_dma ++ [_]u32{0x0000_0010} ++ // NPU_OP_DMA_START
        [_]u32{0x0000_0011} ++ // NPU_OP_DMA_WAIT
        set_ifm_base0 ++ [_]u32{0x0000_0002} ++ // NPU_OP_CONV
        [_]u32{0x0000_0012} ++ // NPU_OP_KERNEL_WAIT
        [_]u32{0xFFFF_0000}; // NPU_OP_STOP, mask 0xFFFF
    const summary = try vela.walk(&words);
    try std.testing.expectEqual(@as(usize, words.len), summary.words);
    try std.testing.expectEqual(@as(usize, 3), summary.register_writes);
    try std.testing.expectEqual(@as(usize, 1), summary.dma_starts);
    try std.testing.expectEqual(@as(usize, 1), summary.conv);
    try std.testing.expectEqual(@as(usize, 2), summary.waits);
    try std.testing.expectEqual(@as(u16, 0xFFFF), summary.stop_mask);
}

test "each block operation counts once" {
    const words = [_]u32{ 0x0000_0002, 0x0000_0003, 0x0000_0005, 0x0000_0006, 0x0000_0001, 0x0000_0000 };
    const summary = try vela.walk(&words);
    try std.testing.expectEqual(@as(usize, 4), summary.operations());
    try std.testing.expectEqual(@as(usize, 1), summary.irqs);
}

test "a payload word that looks like STOP is skipped, not obeyed" {
    const words = [_]u32{ 0x0000_4000, 0x0000_0000, 0x0000_0006, 0x0000_0000 };
    const summary = try vela.walk(&words);
    try std.testing.expectEqual(@as(usize, 4), summary.words);
    try std.testing.expectEqual(@as(usize, 1), summary.elementwise);
}

test "words after the STOP are not part of the program" {
    const words = [_]u32{ 0x0000_0000, 0xDEAD_BEEF };
    try std.testing.expectEqual(@as(usize, 1), (try vela.walk(&words)).words);
}

test "a cmd1 at the end with no payload is truncated" {
    try std.testing.expectError(error.Truncated, vela.walk(&[_]u32{0x0000_4000}));
}

test "a program that never stops is refused" {
    try std.testing.expectError(error.NoStop, vela.walk(&[_]u32{ 0x0000_0002, 0x0000_0012 }));
}

test "modes and opcodes Vela never emits are refused" {
    try std.testing.expectError(error.UnknownMode, vela.walk(&[_]u32{0x0000_8000}));
    try std.testing.expectError(error.UnknownOpcode, vela.walk(&[_]u32{0x0000_0004}));
}

test "the stand-in program's first word is not a Vela command" {
    // cmd.zig's marker sits in the top half; its bottom half is an
    // opcode the stand-in defines, never a Vela cmd0.
    try std.testing.expectEqual(@as(u16, 0xABCD), vela.param(0xABCD_0001));
}

test "cmd0 register sets, such as the DMA region commands, are counted and passed over" {
    // NPU_SET_DMA0_SRC_REGION (0x130) region 1, _DST_REGION (0x131) region 2,
    // NPU_SET_IFM_PAD_TOP (0x100), then NPU_OP_DMA_START and STOP.
    const words = [_]u32{ 0x0001_0130, 0x0002_0131, 0x0000_0100, 0x0000_0010, 0x0000_0000 };
    const summary = try vela.walk(&words);
    try std.testing.expectEqual(@as(usize, 3), summary.register_sets);
    try std.testing.expectEqual(@as(usize, 1), summary.dma_starts);
    try std.testing.expectEqual(@as(usize, 5), summary.words);
}

test "the cmd0 register-set range is 0x100 to 0x18F" {
    try std.testing.expect(vela.isCmd0Set(0x100));
    try std.testing.expect(vela.isCmd0Set(0x18F));
    try std.testing.expect(!vela.isCmd0Set(0x0FF));
    try std.testing.expect(!vela.isCmd0Set(0x190));
    try std.testing.expectError(error.UnknownOpcode, vela.walk(&[_]u32{0x0000_0190}));
}
