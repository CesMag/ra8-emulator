//! Covers src/chip/core/cpu/block/end.zig.
const std = @import("std");
const ra8 = @import("ra8");
const ends = ra8.chip.core.cpu.decode.block.ends;
const Instr = ra8.chip.core.cpu.instr.Instr;

fn narrow(hw1: u16) bool {
    return ends(.{ .address = 0, .hw1 = hw1, .size = 2 });
}

fn wide(hw1: u16, hw2: u16) bool {
    return ends(.{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 });
}

test "narrow flow changes end a block" {
    for ([_]u16{ 0xD001, 0xE7FE, 0x4770, 0x4780, 0x46F7, 0x44FF, 0xBD10, 0xB118, 0xB918, 0xBF08, 0xBE00, 0xDF00, 0xDE00 }) |hw1|
        try std.testing.expect(narrow(hw1));
}

test "narrow straight-line work does not" {
    for ([_]u16{ 0x2001, 0x4601, 0x4408, 0xBF00, 0xBF30, 0xB510, 0x6800, 0xB672 }) |hw1|
        try std.testing.expect(!narrow(hw1));
}

test "wide flow changes end a block" {
    try std.testing.expect(wide(0xF000, 0xF800)); // bl
    try std.testing.expect(wide(0xF040, 0xC001)); // wls
    try std.testing.expect(wide(0xF380, 0x8814)); // msr control
    try std.testing.expect(wide(0xE8BD, 0x8010)); // pop.w {r4, pc}
    try std.testing.expect(wide(0xE8D0, 0xF000)); // tbb
    try std.testing.expect(wide(0xF8DD, 0xF004)); // ldr.w pc, [sp, #4]
    try std.testing.expect(wide(0xE97F, 0xE97F)); // sg
}

test "wide straight-line work does not" {
    try std.testing.expect(!wide(0xE92D, 0x4010)); // push.w {r4, lr}
    try std.testing.expect(!wide(0xF8D0, 0x1004)); // ldr.w r1, [r0, #4]
    try std.testing.expect(!wide(0xFB00, 0xF001)); // mul.w
    try std.testing.expect(!wide(0xE8BD, 0x4010)); // pop.w {r4, lr}
}
