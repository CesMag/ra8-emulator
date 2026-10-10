//! Tests for src/session/disasm.zig.
const std = @import("std");
const ra8 = @import("ra8");
const mod = ra8.session.disasm;

const Error = mod.Error;
const one = mod.one;

test "a Thumb store decodes to its mnemonic and operands" {
    const text = try one(0x2200_0000, &[_]u8{ 0x01, 0x60 });
    try std.testing.expectEqualStrings("str r1, [r0]", text.slice());
}

test "a 32-bit encoding reads both halfwords" {
    // ldr.w r1, [r0, #4]: hw1 0xF8D0, hw2 0x1004.
    const text = try one(0x2200_0000, &[_]u8{ 0xD0, 0xF8, 0x04, 0x10 });
    try std.testing.expectEqualStrings("ldr.w r1, [r0, #4]", text.slice());
}

test "a wide first halfword without its second is an error" {
    try std.testing.expectError(Error.NothingDecoded, one(0x2200_0000, &[_]u8{ 0xD0, 0xF8 }));
}

test "fewer than two bytes is an error" {
    try std.testing.expectError(Error.NothingDecoded, one(0x2200_0000, &[_]u8{0x01}));
}
