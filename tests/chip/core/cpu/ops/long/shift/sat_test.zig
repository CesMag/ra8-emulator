//! Covers src/chip/core/cpu/ops/long_shift_sat.zig. Encodings are the ones
//! arm-none-eabi-as 13.3 emits; expected values follow the DDI0553
//! pseudocode, round half up and saturating clamps setting Q.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const sat = ra8.chip.core.cpu.ops.long.shift.sat;
const table = ra8.chip.core.cpu.ops.table;
const q_bit: u32 = 1 << 27;

const uqshl5: u16 = 0x1F4F; // uqshl r2, #5
const urshr5: u16 = 0x1F5F; // urshr r2, #5
const srshr5: u16 = 0x1F6F; // srshr r2, #5
const sqshl5: u16 = 0x1F7F; // sqshl r2, #5
const uqrshl: u16 = 0x4F0D; // uqrshl r2, r4
const sqrshr: u16 = 0x4F2D; // sqrshr r2, r4

fn wide(hw1: u16, hw2: u16) ra8.chip.core.cpu.instr.Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

const Out = struct { value: u32, q: bool };

/// Runs the op on Rda = r2 (r12 for hw1 0xEA5C) with r4 = `amount`, from
/// a clear Q; checks r4 and the other xPSR bits are untouched.
fn run(hw1: u16, hw2: u16, value: u32, amount: u32) !Out {
    var cpu: Cpu = .{ .bus = undefined };
    const rda: u4 = @intCast(hw1 & 0xF);
    cpu.regs.set(rda, value);
    cpu.regs.set(4, amount);
    cpu.regs.xpsr = 0xF100_0000;
    const instr = wide(hw1, hw2);
    const exec = sat.group.decode(instr) orelse return error.NotClaimed;
    try exec(&cpu, instr);
    try std.testing.expectEqual(@as(u32, 0xF100_0000), cpu.regs.xpsr & ~q_bit);
    if (rda != 4) try std.testing.expectEqual(amount, cpu.regs.get(4));
    return .{ .value = cpu.regs.get(rda), .q = cpu.regs.xpsr & q_bit != 0 };
}

fn expectRun(hw2: u16, value: u32, amount: u32, want: u32, want_q: bool) !void {
    const got = try run(0xEA52, hw2, value, amount);
    try std.testing.expectEqual(want, got.value);
    try std.testing.expectEqual(want_q, got.q);
}

test "the immediate forms decode Rda, the kind and the amount" {
    const f = sat.fields(wide(0xEA52, uqshl5)).?;
    try std.testing.expectEqual(@as(u4, 2), f.rda);
    try std.testing.expectEqual(sat.Kind.uqshl, f.kind);
    try std.testing.expectEqual(@as(u6, 5), f.amount);
    try std.testing.expectEqual(sat.Kind.urshr, sat.fields(wide(0xEA52, urshr5)).?.kind);
    try std.testing.expectEqual(sat.Kind.srshr, sat.fields(wide(0xEA52, srshr5)).?.kind);
    try std.testing.expectEqual(sat.Kind.sqshl, sat.fields(wide(0xEA52, sqshl5)).?.kind);
    try std.testing.expectEqual(@as(u6, 1), sat.fields(wide(0xEA52, 0x0F4F)).?.amount);
    try std.testing.expectEqual(@as(u6, 32), sat.fields(wide(0xEA52, 0x0F1F)).?.amount);
    try std.testing.expectEqual(@as(u6, 31), sat.fields(wide(0xEA5C, 0x7FFF)).?.amount);
}

test "the register forms decode Rda and Rm" {
    const f = sat.fields(wide(0xEA52, uqrshl)).?;
    try std.testing.expectEqual(sat.Kind.uqrshl, f.kind);
    try std.testing.expectEqual(@as(?u4, 4), f.rm);
    try std.testing.expectEqual(sat.Kind.sqrshr, sat.fields(wide(0xEA52, sqrshr)).?.kind);
}

test "uqshl saturates to all ones and sets Q" {
    try expectRun(uqshl5, 0x0100_0000, 0, 0x2000_0000, false);
    try expectRun(uqshl5, 0x0800_0000, 0, 0xFFFF_FFFF, true);
    try expectRun(0x0F4F, 0x8000_0000, 0, 0xFFFF_FFFF, true);
}

test "sqshl saturates toward the sign it started with" {
    try expectRun(sqshl5, 0x0100_0000, 0, 0x2000_0000, false);
    try expectRun(sqshl5, 0xFFFF_FFFF, 0, 0xFFFF_FFE0, false);
    try expectRun(sqshl5, 0x0400_0000, 0, 0x7FFF_FFFF, true);
    try expectRun(sqshl5, 0xF800_0000, 0, 0x8000_0000, true);
    const r12 = try run(0xEA5C, 0x7FFF, 1, 0);
    try std.testing.expectEqual(@as(u32, 0x7FFF_FFFF), r12.value);
    try std.testing.expect(r12.q);
}

test "urshr and srshr round half up and never saturate" {
    try expectRun(urshr5, 0x30, 0, 2, false);
    try expectRun(urshr5, 0x2F, 0, 1, false);
    try expectRun(0x0F1F, 0x8000_0000, 0, 1, false);
    try expectRun(0x0F1F, 0x7FFF_FFFF, 0, 0, false);
    try expectRun(0x0F5F, 0xFFFF_FFFF, 0, 0x8000_0000, false); // urshr #1
    try expectRun(srshr5, 0xFFFF_FFD0, 0, 0xFFFF_FFFF, false); // -1.5 to -1
    try expectRun(srshr5, 0x30, 0, 2, false);
    try expectRun(0x0F2F, 0x8000_0000, 0, 0, false); // srshr #32
    try expectRun(0x0F2F, 0x7FFF_FFFF, 0, 0, false);
}

test "uqrshl goes left saturating and right rounding by the signed byte" {
    try expectRun(uqrshl, 0x1000_0000, 3, 0x8000_0000, false);
    try expectRun(uqrshl, 0x1000_0000, 4, 0xFFFF_FFFF, true);
    try expectRun(uqrshl, 0x0100_0000, 0x0104, 0x1000_0000, false);
    try expectRun(uqrshl, 0x18, 0xFFFF_FFFC, 2, false); // 1.5 to 2
    try expectRun(uqrshl, 0x8000_0000, 0xFFFF_FFE0, 1, false); // -32
    try expectRun(uqrshl, 0xFFFF_FFFF, 0xFFFF_FFDF, 0, false); // -33
    try expectRun(uqrshl, 0, 32, 0, false);
    try expectRun(uqrshl, 1, 32, 0xFFFF_FFFF, true);
}

test "sqrshr goes right rounding and left saturating by the signed byte" {
    try expectRun(sqrshr, 0xFFFF_FFE8, 4, 0xFFFF_FFFF, false); // -1.5 to -1
    try expectRun(sqrshr, 0x8000_0000, 31, 0xFFFF_FFFF, false);
    try expectRun(sqrshr, 0x8000_0000, 32, 0, false);
    try expectRun(sqrshr, 0x0800_0000, 0xFFFF_FFFC, 0x7FFF_FFFF, true);
    try expectRun(sqrshr, 0xFFFF_FFFB, 0x80, 0x8000_0000, true); // -128: left 128
    try expectRun(sqrshr, 0, 0x80, 0, false);
}

test "a result that does not saturate leaves Q as it was" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.set(2, 1);
    cpu.regs.xpsr = q_bit;
    const instr = wide(0xEA52, uqshl5);
    try sat.group.decode(instr).?(&cpu, instr);
    try std.testing.expectEqual(@as(u32, 32), cpu.regs.get(2));
    try std.testing.expectEqual(q_bit, cpu.regs.xpsr);
}

test "the forms this group leaves alone" {
    const left = [_][2]u16{
        .{ 0xEA5D, uqshl5 }, // Rda = SP
        .{ 0xEA5F, uqshl5 }, // Rda = PC
        .{ 0xEA52, 0x9F4F }, // hw2 bit 15 set
        .{ 0xEA52, 0x4F1D }, // register type 01
        .{ 0xEA52, 0x4F3D }, // register type 11
        .{ 0xEA52, 0x4F4D }, // register hw2 bit 6 set
        .{ 0xEA52, 0xDF0D }, // Rm = SP
        .{ 0xEA52, 0xFF0D }, // Rm = PC
        .{ 0xEA52, 0x2F0D }, // Rm = Rda
        .{ 0xEA52, 0x134F }, // lsll r2, r3, #5
        .{ 0xEA52, 0x430D }, // lsll r2, r3, r4
    };
    for (left) |pair| try std.testing.expect(sat.group.decode(wide(pair[0], pair[1])) == null);
}

test "no earlier group claims these encodings" {
    const mine = [_][2]u16{
        .{ 0xEA52, uqshl5 }, .{ 0xEA52, urshr5 }, .{ 0xEA52, srshr5 },
        .{ 0xEA52, sqshl5 }, .{ 0xEA52, uqrshl }, .{ 0xEA52, sqrshr },
        .{ 0xEA5C, 0x7FFF }, .{ 0xEA53, uqshl5 },
    };
    for (mine) |pair| {
        for (table.groups) |g| {
            if (g.decode(wide(pair[0], pair[1])) == null) continue;
            try std.testing.expectEqualStrings("long_shift_sat", g.name);
            break;
        }
    }
}

test "the group has a lockstep oracle" {
    try std.testing.expect(sat.group.oracle);
}

test "seam port: uqshl r2, #5 clamps to all ones and sets Q" {
    try expectRun(uqshl5, 0x0800_0000, 0, 0xFFFF_FFFF, true);
}
