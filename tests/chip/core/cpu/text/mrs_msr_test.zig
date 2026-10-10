//! Covers src/chip/core/cpu/text/mrs_msr.zig: against its parity digest for every SYSm it
//! decodes, and by name for the PAC key registers the reference
//! disassembler could not decode.
const std = @import("std");
const ra8 = @import("ra8");
const parity = @import("parity.zig");
const Instr = ra8.chip.core.cpu.instr.Instr;

/// Every SYSm the group claims except the PAC keys, plus 0x0C (unclaimed).
const sysms = [_]u8{
    0,  1,  2,  3,  5,    6,    7,    8,    9,    10,   11,   0x0C, 16,
    17, 18, 19, 20, 0x88, 0x89, 0x8A, 0x8B, 0x90, 0x91, 0x93, 0x94, 0x98,
};

/// Each SYSm with hw2[11:10] = 1, 2 and 3: the MSR mask, or the top of the
/// MRS Rd (so Rd 4, 8 and 12). Rd = SP and PC stay unclaimed.
const hw2 = blk: {
    var out: [sysms.len * 3 + 2]u16 = undefined;
    for (sysms, 0..) |n, i| {
        for (0..3) |m| out[i * 3 + m] = 0x8000 | (@as(u16, m + 1) << 10) | n;
    }
    out[sysms.len * 3] = 0x8D08;
    out[sysms.len * 3 + 1] = 0x8F14;
    break :blk out;
};

test "MRS matches its parity digest for every SYSm" {
    try parity.expectWideGroupMatches("mrs_msr", 0xFFFF, 0xF3EF, &hw2);
}

test "MSR matches its parity digest for every SYSm and mask" {
    try parity.expectWideGroupMatches("mrs_msr", 0xFFF0, 0xF380, &hw2);
}

fn expectText(hw1: u16, hw2_value: u16, want: []const u8) !void {
    const instr: Instr = .{ .address = parity.address, .hw1 = hw1, .hw2 = hw2_value, .size = 4 };
    const got = ra8.chip.core.cpu.decode.text.disasm.one(instr) orelse return error.Unclaimed;
    try std.testing.expectEqualStrings(want, got.slice());
}

test "the PAC key registers print their Arm names" {
    try expectText(0xF3EF, 0x8320, "mrs r3, pac_key_p_0");
    try expectText(0xF3EF, 0x8327, "mrs r3, pac_key_u_3");
    try expectText(0xF384, 0x8823, "msr pac_key_p_3, r4");
    try expectText(0xF384, 0x8824, "msr pac_key_u_0, r4");
}
