//! Covers src/chip/core/cpu/ops/eci_use.zig and the ECI kind the decode table
//! hands each group's encodings (RA8EMU-453).
const std = @import("std");
const ra8 = @import("ra8");
const decode = ra8.chip.core.cpu.decode;
const Instr = ra8.chip.core.cpu.instr.Instr;
const Eci = ra8.chip.core.cpu.op.Eci;

fn narrow(hw1: u16) Instr {
    return .{ .address = 0x100, .hw1 = hw1, .hw2 = 0, .size = 2 };
}

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0x100, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn kind(instr: Instr) !Eci {
    const hit = decode.decode(instr) orelse return error.NotClaimed;
    return hit.eci;
}

test "plain instructions refuse ECI" {
    try std.testing.expectEqual(Eci.refuses, try kind(narrow(0xBF00))); // nop
    try std.testing.expectEqual(Eci.refuses, try kind(narrow(0x1888))); // adds r0, r1, r2
}

test "load and store multiples restart" {
    try std.testing.expectEqual(Eci.restarts, try kind(narrow(0xC802))); // ldmia r0!, {r1}
    try std.testing.expectEqual(Eci.restarts, try kind(narrow(0xB403))); // push {r0, r1}
    try std.testing.expectEqual(Eci.restarts, try kind(wide(0xE8BD, 0x0003))); // pop.w {r0, r1}
}

test "BKPT, LE and LETP keep ECI; DLS, DLSTP and LCTP refuse it" {
    try std.testing.expectEqual(Eci.keeps, try kind(narrow(0xBE00)));
    try std.testing.expectEqual(Eci.keeps, try kind(wide(0xF00F, 0xC007))); // le
    try std.testing.expectEqual(Eci.keeps, try kind(wide(0xF01F, 0xC80F))); // letp
    try std.testing.expectEqual(Eci.refuses, try kind(wide(0xF042, 0xE001))); // dls lr, r2
    try std.testing.expectEqual(Eci.refuses, try kind(wide(0xF022, 0xE001))); // dlstp.32 lr, r2
    try std.testing.expectEqual(Eci.refuses, try kind(wide(0xF00F, 0xE001))); // lctp
}

test "beat-wise MVE groups honour ECI" {
    for ([_]Instr{
        wide(0xEF22, 0x0844), // vadd.i32
        wide(0xFE71, 0x0F4D), // vpst
        wide(0xEEA0, 0x1B10), // vdup.32
        wide(0xFE41, 0x0F83), // vpt.u8
        wide(0xEE73, 0x1F04), // vpt.f32
    }) |instr| try std.testing.expectEqual(Eci.beat_wise, try kind(instr));
}

test "FP multiples restart while single transfers refuse ECI" {
    for ([_]Instr{
        wide(0xEC92, 0x0A02), // vldmia r2, {s0-s1}
        wide(0xEC82, 0x0A02), // vstmia r2, {s0-s1}
        wide(0xED2D, 0x0A02), // vpush {s0-s1}
        wide(0xECBD, 0x0A02), // vpop {s0-s1}
    }) |instr| try std.testing.expectEqual(Eci.restarts, try kind(instr));
    for ([_]Instr{
        wide(0xED90, 0x0A00), // vldr s0, [r0]
        wide(0xED80, 0x0A00), // vstr s0, [r0]
    }) |instr| try std.testing.expectEqual(Eci.refuses, try kind(instr));
}
