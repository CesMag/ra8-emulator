//! Helper for the Armv8.1-M printer tests, which check against Arm ARM syntax
//! because the reference disassembler had no Armv8.1-M.
const std = @import("std");
const ra8 = @import("ra8");
const disasm = ra8.chip.core.cpu.decode.text.disasm;
const Instr = ra8.chip.core.cpu.instr.Instr;

pub const Case = struct { hw1: u16, hw2: u16, text: []const u8 };

/// Each case decodes as a 32-bit instruction and prints exactly `text`.
pub fn expectTexts(cases: []const Case) !void {
    for (cases) |case| {
        const instr: Instr = .{ .address = 0x0200_0100, .hw1 = case.hw1, .hw2 = case.hw2, .size = 4 };
        const got = disasm.one(instr) orelse {
            std.debug.print("{x:0>4} {x:0>4}: no text, want \"{s}\"\n", .{ case.hw1, case.hw2, case.text });
            return error.TestExpectedEqual;
        };
        std.testing.expectEqualStrings(case.text, got.slice()) catch |err| {
            std.debug.print("at {x:0>4} {x:0>4}\n", .{ case.hw1, case.hw2 });
            return err;
        };
    }
}

/// Checks one T-predicated instruction following a VPST whose mask is TE.
pub fn expectPredicated(case: Case, expected: []const u8) !void {
    const vpst: Instr = .{ .address = 0x0200_0100, .hw1 = 0xFE71, .hw2 = 0x8F4D, .size = 4 };
    const instr: Instr = .{ .address = 0x0200_0104, .hw1 = case.hw1, .hw2 = case.hw2, .size = 4 };
    var stream: disasm.Stream = .{};
    try std.testing.expectEqualStrings("vpste", stream.format(vpst).?.slice());
    try std.testing.expectEqualStrings(expected, stream.format(instr).?.slice());
}
