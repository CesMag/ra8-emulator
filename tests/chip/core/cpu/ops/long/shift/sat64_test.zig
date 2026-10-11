//! Covers src/chip/core/cpu/ops/long/shift/sat64.zig. Encodings are the ones
//! arm-none-eabi-as 13.3 emits for the r2:r3 pair (Rm r4); expected values
//! follow the DDI0553 pseudocode, round half up and saturation setting Q.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const sat = ra8.chip.core.cpu.ops.long.shift.sat64;
const table = ra8.chip.core.cpu.ops.table;
const q_bit: u32 = 1 << 27;

const hw1: u16 = 0xEA53;
const uqshll5: u16 = 0x134F;
const urshrl5: u16 = 0x135F;
const srshrl5: u16 = 0x136F;
const sqshll5: u16 = 0x137F;
const urshrl32: u16 = 0x031F;
const urshrl1: u16 = 0x035F;
const srshrl32: u16 = 0x032F;
const uqrshll64: u16 = 0x430D;
const sqrshrl64: u16 = 0x432D;
const uqrshll48: u16 = 0x438D;
const sqrshrl48: u16 = 0x43AD;

const min64: u64 = 0x8000_0000_0000_0000;
const max64: u64 = 0x7FFF_FFFF_FFFF_FFFF;
const all: u64 = ~@as(u64, 0);

fn wide(first: u16, second: u16) ra8.chip.core.cpu.instr.Instr {
    return .{ .address = 0, .hw1 = first, .hw2 = second, .size = 4 };
}

/// Runs the op on r2:r3 with r4 = `amount` from a clear Q; checks r4 and
/// the other xPSR bits are untouched, then checks the pair and Q.
fn expectRun(hw2: u16, value: u64, amount: u32, want: u64, want_q: bool) !void {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.set(2, @truncate(value));
    cpu.regs.set(3, @truncate(value >> 32));
    cpu.regs.set(4, amount);
    cpu.regs.xpsr = 0xF100_0000;
    const instr = wide(hw1, hw2);
    const exec = sat.group.decode(instr) orelse return error.NotClaimed;
    try exec(&cpu, instr);
    try std.testing.expectEqual(@as(u32, 0xF100_0000), cpu.regs.xpsr & ~q_bit);
    try std.testing.expectEqual(amount, cpu.regs.get(4));
    const got = (@as(u64, cpu.regs.get(3)) << 32) | cpu.regs.get(2);
    try std.testing.expectEqual(want, got);
    try std.testing.expectEqual(want_q, cpu.regs.xpsr & q_bit != 0);
}

test "the immediate forms decode the pair, the kind and the amount" {
    const f = sat.fields(wide(hw1, uqshll5)).?;
    try std.testing.expectEqual(@as(u4, 2), f.lo);
    try std.testing.expectEqual(@as(u4, 3), f.hi);
    try std.testing.expectEqual(sat.Kind.uqshll, f.kind);
    try std.testing.expectEqual(@as(u6, 5), f.amount);
    try std.testing.expectEqual(sat.Kind.urshrl, sat.fields(wide(hw1, urshrl5)).?.kind);
    try std.testing.expectEqual(sat.Kind.srshrl, sat.fields(wide(hw1, srshrl5)).?.kind);
    try std.testing.expectEqual(sat.Kind.sqshll, sat.fields(wide(hw1, sqshll5)).?.kind);
    try std.testing.expectEqual(@as(u6, 32), sat.fields(wide(hw1, urshrl32)).?.amount);
    try std.testing.expectEqual(@as(u6, 1), sat.fields(wide(hw1, urshrl1)).?.amount);
}

test "the register forms decode Rm and where they saturate" {
    const f = sat.fields(wide(hw1, uqrshll64)).?;
    try std.testing.expectEqual(sat.Kind.uqrshll, f.kind);
    try std.testing.expectEqual(@as(?u4, 4), f.rm);
    try std.testing.expectEqual(@as(u7, 64), f.bits);
    try std.testing.expectEqual(@as(u7, 48), sat.fields(wide(hw1, uqrshll48)).?.bits);
    try std.testing.expectEqual(sat.Kind.sqrshrl, sat.fields(wide(hw1, sqrshrl48)).?.kind);
    try std.testing.expectEqual(@as(u7, 64), sat.fields(wide(hw1, sqrshrl64)).?.bits);
}

test "uqshll and sqshll saturate and set Q" {
    try expectRun(uqshll5, 0x1_0000_0000, 0, 0x20_0000_0000, false);
    try expectRun(uqshll5, 0x0800_0000_0000_0000, 0, all, true);
    try expectRun(sqshll5, all, 0, all - 31, false); // -1 << 5 = -32
    try expectRun(sqshll5, 0x0400_0000_0000_0000, 0, max64, true);
    try expectRun(sqshll5, 0xF800_0000_0000_0000, 0, min64, true);
}

test "urshrl and srshrl round half up and never saturate" {
    try expectRun(urshrl5, 0x30, 0, 2, false);
    try expectRun(urshrl5, 0x2F, 0, 1, false);
    try expectRun(urshrl32, 0x8000_0000, 0, 1, false);
    try expectRun(urshrl32, 0x7FFF_FFFF, 0, 0, false);
    try expectRun(urshrl1, all, 0, min64, false);
    try expectRun(srshrl5, 0xFFFF_FFFF_FFFF_FFD0, 0, all, false); // -1.5 to -1
    try expectRun(srshrl32, 0xFFFF_FFFF_8000_0000, 0, 0, false); // -0.5 to 0
}

test "uqrshll at 64 bits goes left saturating and right rounding" {
    try expectRun(uqrshll64, 0x1000_0000_0000_0000, 3, min64, false);
    try expectRun(uqrshll64, 0x1000_0000_0000_0000, 4, all, true);
    try expectRun(uqrshll64, 0x18, 0xFFFF_FFFC, 2, false); // 1.5 to 2
    try expectRun(uqrshll64, min64, 0xC0, 1, false); // -64
    try expectRun(uqrshll64, all, 0xBF, 0, false); // -65
    try expectRun(uqrshll64, 1, 0x0140, all, true); // bottom byte 64
    try expectRun(uqrshll64, 0, 64, 0, false);
}

test "sqrshrl at 64 bits goes right rounding and left saturating" {
    try expectRun(sqrshrl64, 0xFFFF_FFFF_FFFF_FFE8, 4, all, false); // -1.5 to -1
    try expectRun(sqrshrl64, min64, 63, all, false);
    try expectRun(sqrshrl64, min64, 64, 0, false);
    try expectRun(sqrshrl64, 0x0800_0000_0000_0000, 0xFFFF_FFFC, max64, true);
    try expectRun(sqrshrl64, 0xFFFF_FFFF_FFFF_FFFB, 0x80, min64, true); // left 128
}

test "the 48-bit forms saturate at 48 bits and extend into the pair" {
    try expectRun(uqrshll48, 0x1000_0000_0000, 3, 0x8000_0000_0000, false);
    try expectRun(uqrshll48, 0x1000_0000_0000, 4, 0xFFFF_FFFF_FFFF, true);
    try expectRun(uqrshll48, 1 << 60, 0xFFFF_FFFC, 0xFFFF_FFFF_FFFF, true);
    try expectRun(uqrshll48, 0x8000_0000_0000, 0xD0, 1, false); // -48
    try expectRun(uqrshll48, all, 0xCF, 0, false); // -49
    try expectRun(sqrshrl48, 0x4000_0000_0000, 0xFF, 0x7FFF_FFFF_FFFF, true);
    try expectRun(sqrshrl48, 0xFFFF_C000_0000_0000, 0xFF, 0xFFFF_8000_0000_0000, false);
    try expectRun(sqrshrl48, 0xFFFF_8000_0000_0000, 0xFF, 0xFFFF_8000_0000_0000, true);
    try expectRun(sqrshrl48, 0xFFFF_FFFF_FFFF_FFE8, 4, all, false);
    try expectRun(sqrshrl48, all, 48, 0, false);
}

test "the forms this group leaves alone" {
    const left = [_][2]u16{
        .{ hw1, 0x1D4F }, // RdaHi = SP
        .{ hw1, 0x1F4F }, // RdaHi 1111: uqshl r3, #5
        .{ hw1, 0x124F }, // hw2 bit 8 clear
        .{ hw1, 0x934F }, // hw2 bit 15 set
        .{ hw1, 0x431D }, // register type 01
        .{ hw1, 0x433D }, // register type 11
        .{ hw1, 0x434D }, // register hw2 bit 6 set
        .{ hw1, 0xD30D }, // Rm = SP
        .{ hw1, 0xF30D }, // Rm = PC
        .{ hw1, 0x230D }, // Rm = RdaLo
        .{ hw1, 0x330D }, // Rm = RdaHi
        .{ 0xEA52, uqshll5 }, // lsll r2, r3, #5
        .{ 0xEA52, uqrshll64 }, // lsll r2, r3, r4
    };
    for (left) |pair| try std.testing.expect(sat.group.decode(wide(pair[0], pair[1])) == null);
}

test "no earlier group claims these encodings" {
    const mine = [_]u16{ uqshll5, urshrl5, srshrl5, sqshll5, urshrl32, uqrshll64, sqrshrl64, uqrshll48, sqrshrl48 };
    for (mine) |hw2| {
        for (table.groups) |g| {
            if (g.decode(wide(hw1, hw2)) == null) continue;
            try std.testing.expectEqualStrings("long_shift_sat64", g.name);
            break;
        }
    }
}

test "the group has a lockstep oracle" {
    try std.testing.expect(sat.group.oracle);
}

test "seam port: uqshll r2, r3, #5 clamps the pair and sets Q" {
    var cpu: ra8.chip.core.cpu.cpu.Cpu = .{ .bus = undefined };
    cpu.regs.low[3] = 0x0800_0000;
    const instr: ra8.chip.core.cpu.instr.Instr = .{ .address = 0, .hw1 = 0xEA53, .hw2 = 0x134F, .size = 4 };
    const exec = ra8.chip.core.cpu.ops.long.shift.sat64.group.decode(instr) orelse return error.NotClaimed;
    try exec(&cpu, instr);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), cpu.regs.low[2]);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), cpu.regs.low[3]);
    try std.testing.expect(cpu.regs.xpsr & (1 << 27) != 0);
}
