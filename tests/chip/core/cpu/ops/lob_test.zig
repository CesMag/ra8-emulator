//! Covers src/chip/core/cpu/ops/lob.zig. Encodings are the ones
//! arm-none-eabi-as 13.3 emits for armv8.1-m.main, laid out as
//!
//!     0x00  f042 e001  dls  lr, r2
//!     0x04  bf00       nop
//!     0x06  bf00       nop
//!     0x08  f00f c007  le   lr, 0x00
//!     0x0c  f043 c801  wls  lr, r3, 0x12
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const lob = ra8.chip.core.cpu.ops.lob;
const table = ra8.chip.core.cpu.ops.table;

const dls_r2 = [2]u16{ 0xF042, 0xE001 };
const le_back = [2]u16{ 0xF00F, 0xC007 };
const wls_r3 = [2]u16{ 0xF043, 0xC801 };
const flags: u32 = 0xF100_0000;

fn wide(at: u32, pair: [2]u16) ra8.chip.core.cpu.instr.Instr {
    return .{ .address = at, .hw1 = pair[0], .hw2 = pair[1], .size = 4 };
}

/// Runs one loop instruction at `at` the way the core does (PC already past
/// it) and checks the flags are untouched.
fn step(cpu: *Cpu, at: u32, pair: [2]u16) !void {
    const instr = wide(at, pair);
    const exec = lob.group.decode(instr) orelse return error.NotClaimed;
    cpu.regs.pc = at + 4;
    try exec(cpu, instr);
    try std.testing.expectEqual(flags, cpu.regs.xpsr);
}

fn fresh() Cpu {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.xpsr = flags;
    return cpu;
}

test "dls lr, r2 loads the counter and falls through" {
    var cpu = fresh();
    cpu.regs.low[2] = 9;
    try step(&cpu, 0x00, dls_r2);
    try std.testing.expectEqual(@as(u32, 9), cpu.regs.lr);
    try std.testing.expectEqual(@as(u32, 0x04), cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 9), cpu.regs.low[2]);
}

test "dls lr, r12 reads a high register" {
    var cpu = fresh();
    cpu.regs.set(12, 3);
    try step(&cpu, 0x1C, .{ 0xF04C, 0xE001 });
    try std.testing.expectEqual(@as(u32, 3), cpu.regs.lr);
}

test "wls on a zero count skips the body and leaves LR alone" {
    var cpu = fresh();
    cpu.regs.lr = 0x1234;
    try step(&cpu, 0x0C, wls_r3);
    try std.testing.expectEqual(@as(u32, 0x12), cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0x1234), cpu.regs.lr);
}

test "wls on a non-zero count loads LR and enters the body" {
    var cpu = fresh();
    cpu.regs.low[3] = 5;
    try step(&cpu, 0x0C, wls_r3);
    try std.testing.expectEqual(@as(u32, 0x10), cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 5), cpu.regs.lr);
}

test "le loops back while the counter stays non-zero, then falls out" {
    var cpu = fresh();
    cpu.regs.lr = 3;
    try step(&cpu, 0x08, le_back);
    try std.testing.expectEqual(@as(u32, 0x00), cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 2), cpu.regs.lr);
    cpu.regs.lr = 1;
    try step(&cpu, 0x08, le_back);
    try std.testing.expectEqual(@as(u32, 0x0C), cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.lr);
    try step(&cpu, 0x08, le_back);
    try std.testing.expectEqual(@as(u32, 0x0C), cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.lr);
}

test "dls lr, rn runs the body exactly rn times" {
    var cpu = fresh();
    cpu.regs.low[2] = 4;
    try step(&cpu, 0x00, dls_r2);
    var bodies: u32 = 0;
    while (true) {
        bodies += 1; // the two nops
        try step(&cpu, 0x08, le_back);
        if (cpu.regs.pc == 0x0C) break;
        try std.testing.expectEqual(@as(u32, 0x00), cpu.regs.pc);
    }
    try std.testing.expectEqual(@as(u32, 4), bodies);
}

test "sp and pc sources, the tail-predicated forms and narrow halfwords stay unclaimed" {
    const left = [_][2]u16{
        .{ 0xF04D, 0xE001 }, // dls lr, sp
        .{ 0xF04F, 0xE001 }, // dls lr, pc
        .{ 0xF04D, 0xC801 }, // wls lr, sp
        .{ 0xF022, 0xE001 }, // dlstp.32 lr, r2
        .{ 0xF01F, 0xC00F }, // letp lr
        .{ 0xF042, 0xE002 }, // not a dls
    };
    for (left) |pair| try std.testing.expect(lob.group.decode(wide(0, pair)) == null);
    try std.testing.expect(lob.group.decode(.{ .address = 0, .hw1 = 0xF042, .size = 2 }) == null);
}

test "no earlier group claims dls, wls or le" {
    for ([_][2]u16{ dls_r2, le_back, wls_r3 }) |pair| {
        for (table.groups) |g| {
            if (g.decode(wide(0, pair)) == null) continue;
            try std.testing.expectEqualStrings("lob", g.name);
            break;
        } else return error.NotClaimed;
    }
}

test "the group has a lockstep oracle" {
    try std.testing.expect(lob.group.oracle);
}

const fpca = ra8.chip.core.cpu.regs.control_bits.fpca;

/// LE at 0x08 with LR = 3, after an FP context opened or not.
fn leWith(fp_active: bool, ltpsize: u3) Cpu {
    var cpu = fresh();
    if (fp_active) cpu.regs.control |= fpca;
    cpu.fp.fpscr.ltpsize = ltpsize;
    cpu.regs.lr = 3;
    return cpu;
}

test "le with an FP context active and LTPSIZE not 4 is INVSTATE, state untouched" {
    var cpu = leWith(true, 2);
    try std.testing.expectError(error.InvalidState, step(&cpu, 0x08, le_back));
    try std.testing.expectEqual(@as(u32, 3), cpu.regs.lr);
    try std.testing.expectEqual(@as(u32, 0x0C), cpu.regs.pc);
}

test "le loops as before when LTPSIZE is 4 or no FP context is active" {
    for ([_]Cpu{ leWith(true, 4), leWith(false, 2) }) |start| {
        var cpu = start;
        try step(&cpu, 0x08, le_back);
        try std.testing.expectEqual(@as(u32, 2), cpu.regs.lr);
        try std.testing.expectEqual(@as(u32, 0x00), cpu.regs.pc);
    }
}
