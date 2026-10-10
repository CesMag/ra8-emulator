//! Covers MVE printers and the DDI0553 B5.5 VPT/VPST suffix table.
const std = @import("std");
const ra8 = @import("ra8");
const Instr = ra8.chip.core.cpu.instr.Instr;
const disasm = ra8.chip.core.cpu.decode.text.disasm;
const vpst_text = ra8.chip.core.cpu.decode.text.mve_vpst;
const v81m = @import("v81m.zig");

const Pattern = struct { mask: u4, name: []const u8, suffixes: []const u8 };

fn vpstInstr(mask: u4) Instr {
    return .{
        .address = 0x0200_0100,
        .hw1 = 0xFE31 | (@as(u16, mask >> 3) << 6),
        .hw2 = 0x0F4D | (@as(u16, mask & 7) << 13),
        .size = 4,
    };
}

test "VPST names and T/E decorators follow all DDI0553 B5.5 mask encodings" {
    const cases = [_]Pattern{
        .{ .mask = 8, .name = "vpst", .suffixes = "t" },
        .{ .mask = 4, .name = "vpstt", .suffixes = "tt" },
        .{ .mask = 12, .name = "vpste", .suffixes = "te" },
        .{ .mask = 2, .name = "vpsttt", .suffixes = "ttt" },
        .{ .mask = 6, .name = "vpstte", .suffixes = "tte" },
        .{ .mask = 10, .name = "vpstee", .suffixes = "tee" },
        .{ .mask = 14, .name = "vpstet", .suffixes = "tet" },
        .{ .mask = 1, .name = "vpstttt", .suffixes = "tttt" },
        .{ .mask = 3, .name = "vpsttte", .suffixes = "ttte" },
        .{ .mask = 5, .name = "vpsttee", .suffixes = "ttee" },
        .{ .mask = 7, .name = "vpsttet", .suffixes = "ttet" },
        .{ .mask = 9, .name = "vpsteee", .suffixes = "teee" },
        .{ .mask = 11, .name = "vpsteet", .suffixes = "teet" },
        .{ .mask = 13, .name = "vpstett", .suffixes = "tett" },
        .{ .mask = 15, .name = "vpstete", .suffixes = "tete" },
    };
    for (cases) |case| {
        const instr = vpstInstr(case.mask);
        const got = disasm.one(instr) orelse return error.NoPrinter;
        try std.testing.expectEqualStrings(case.name, got.slice());
        const rendered = vpst_text.pattern(instr);
        try std.testing.expectEqualStrings(case.suffixes, rendered.suffixes[0..rendered.len]);
    }
}

test "VPT compare opens the following predicated instruction block" {
    const vpt: Instr = .{ .address = 0x0200_0100, .hw1 = 0xFE41, .hw2 = 0x0F83, .size = 4 };
    const add: Instr = .{ .address = 0x0200_0104, .hw1 = 0xEF22, .hw2 = 0x0844, .size = 4 };
    var stream: disasm.Stream = .{};
    try std.testing.expectEqualStrings("vpt.u8 hi, q0, q1", stream.format(vpt).?.slice());
    try std.testing.expectEqualStrings("vaddt.i32 q0, q1, q2", stream.format(add).?.slice());
}

test "stream appends then and else decorators to the following MVE operations" {
    const vpst = vpstInstr(12);
    const add_t: Instr = .{ .address = 0x0200_0104, .hw1 = 0xEF22, .hw2 = 0x0844, .size = 4 };
    const add_e: Instr = .{ .address = 0x0200_0108, .hw1 = 0xEF22, .hw2 = 0x0844, .size = 4 };
    const outside: Instr = .{ .address = 0x0200_010C, .hw1 = 0xEF22, .hw2 = 0x0844, .size = 4 };
    var stream: disasm.Stream = .{};
    try std.testing.expectEqualStrings("vpste", stream.format(vpst).?.slice());
    try std.testing.expectEqualStrings("vaddt.i32 q0, q1, q2", stream.format(add_t).?.slice());
    try std.testing.expectEqualStrings("vadde.i32 q0, q1, q2", stream.format(add_e).?.slice());
    try std.testing.expectEqualStrings("vadd.i32 q0, q1, q2", stream.format(outside).?.slice());
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xFE41, .hw2 = 0x0F83, .text = "vpt.u8 hi, q0, q1" },
        .{ .hw1 = 0xFE01, .hw2 = 0x0F02, .text = "vcmp.i8 eq, q0, q1" },
        .{ .hw1 = 0xEE73, .hw2 = 0x1F04, .text = "vpt.f32 ge, q1, q2" },
        .{ .hw1 = 0xFE33, .hw2 = 0x0F04, .text = "vcmp.f16 eq, q1, q2" },
        .{ .hw1 = 0xEF22, .hw2 = 0x0844, .text = "vadd.i32 q0, q1, q2" },
    });
}
