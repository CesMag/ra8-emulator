//! Covers src/chip/core/cpu/ops/mve/lane/move.zig. The encodings come from
//! LLVM's assembler for -mcpu=cortex-m85 with MVE.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const lane_move = ra8.chip.core.cpu.ops.mve.lane.move;
const qreg = ra8.chip.core.cpu.mve.qreg;
const vpt = ra8.chip.core.cpu.mve.vpt;
const decode = ra8.chip.core.cpu.decode;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = lane_move.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

fn expectLane(hw1: u16, hw2: u16, size: qreg.Size, q: u3, elem: u8) !void {
    const lane = lane_move.laneOf(wide(hw1, hw2)) orelse return error.Undefined;
    try std.testing.expectEqual(size, lane.size);
    try std.testing.expectEqual(q, lane.q);
    try std.testing.expectEqual(elem, lane.elem);
}

test "laneOf maps the scalar Dd[x] onto Q lanes" {
    try expectLane(0xEE20, 0x1B10, .word, 0, 1);
    try expectLane(0xEE01, 0x1B10, .word, 0, 2);
    try expectLane(0xEE20, 0x1B70, .half, 0, 3);
    try expectLane(0xEE63, 0x2B70, .byte, 1, 15);
    try expectLane(0xEE93, 0x1B70, .half, 1, 5);
    try expectLane(0xEE3F, 0x1B10, .word, 7, 3);
}

test "vmov.8 q1[15], r2 replaces only that byte" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 1, 0x1111);
    cpu.regs.set(2, 0x1234_56AB);
    try run(&cpu, 0xEE63, 0x2B70);
    try std.testing.expectEqual((@as(u128, 0xAB) << 120) | 0x1111, qreg.read(&cpu.fp.bank, 1));
}

test "vmov.32 q0[2], r1 writes word 2 and leaves VPT alone" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.set(1, 0xCAFE_F00D);
    cpu.fp.vpr = vpt.open(.{ .p0 = 0 }, 0b1000);
    const before = cpu.fp.vpr;
    try run(&cpu, 0xEE01, 0x1B10);
    try std.testing.expectEqual(@as(u128, 0xCAFE_F00D) << 64, qreg.read(&cpu.fp.bank, 0));
    try std.testing.expectEqual(before, cpu.fp.vpr);
}

test "vmov.s8 sign-extends and vmov.u16 zero-extends" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 1, (@as(u128, 0x80) << 120) | (@as(u128, 0xF00D) << 80));
    try run(&cpu, 0xEE73, 0x1B70);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FF80), cpu.regs.get(1));
    try run(&cpu, 0xEE93, 0x1B70);
    try std.testing.expectEqual(@as(u32, 0xF00D), cpu.regs.get(1));
}

test "vmov.32 r1, q7[3] reads the top word" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 7, @as(u128, 0x8765_4321) << 96);
    try run(&cpu, 0xEE3F, 0x1B10);
    try std.testing.expectEqual(@as(u32, 0x8765_4321), cpu.regs.get(1));
}

test "the table routes both directions here" {
    for ([_][2]u16{ .{ 0xEE20, 0x1B10 }, .{ 0xEE63, 0x2B70 }, .{ 0xEE73, 0x1B70 }, .{ 0xEE3F, 0x1B10 } }) |e| {
        const hit = decode.decode(wide(e[0], e[1])) orelse return error.NotClaimed;
        try std.testing.expectEqualStrings("mve_lane_move", hit.group);
    }
}

test "unclaimed: D16+, U with a word, opc 0x10, Rt of 13 and 15, VDUP" {
    try std.testing.expect(lane_move.group.decode(wide(0xEE20, 0x1B90)) == null);
    try std.testing.expect(lane_move.group.decode(wide(0xEEB0, 0x1B10)) == null);
    try std.testing.expect(lane_move.group.decode(wide(0xEE00, 0x1B50)) == null);
    try std.testing.expect(lane_move.group.decode(wide(0xEE20, 0xDB10)) == null);
    try std.testing.expect(lane_move.group.decode(wide(0xEE30, 0xFB10)) == null);
    try std.testing.expect(lane_move.group.decode(wide(0xEEA0, 0x1B10)) == null);
}

test "a lane in a beat ECI marks done is not moved, and ECI moves on" {
    const it_state = ra8.chip.core.cpu.it_state;
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.xpsr = it_state.put(0, 0x20);
    cpu.regs.set(1, 0xDEAD_BEEF);
    try run(&cpu, 0xEE20, 0x1B10);
    try std.testing.expectEqual(@as(u128, 0), qreg.read(&cpu.fp.bank, 0));
    try std.testing.expectEqual(@as(u8, 0), it_state.get(cpu.regs.xpsr));
    cpu.regs.xpsr = it_state.put(0, 0x50);
    try run(&cpu, 0xEE2F, 0x1B10);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), qreg.elem(qreg.read(&cpu.fp.bank, 7), .word, 3));
    try std.testing.expectEqual(@as(u8, 0x10), it_state.get(cpu.regs.xpsr));
}
