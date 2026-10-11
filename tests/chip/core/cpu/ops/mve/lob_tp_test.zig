//! Covers src/chip/core/cpu/ops/mve_lob_tp.zig. The encodings come from LLVM's
//! assembler for -mcpu=cortex-m85 with MVE, laid out as one listing:
//! dlstp at 0x00..0x0C, wlstp.8 at 0x10, wlstp.32 at 0x14, letp at 0x1A
//! back to 0x00, lctp at 0x2E, and the wlstp target at 0x32.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const tp = ra8.chip.core.cpu.ops.mve.lob_tp;
const decode = ra8.chip.core.cpu.decode;

fn at(address: u32, hw1: u16, hw2: u16) Instr {
    return .{ .address = address, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, instr: Instr) !void {
    const exec = tp.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

test "the fields of each form" {
    const d = tp.fields(at(0x08, 0xF02C, 0xE001)).?;
    try std.testing.expectEqual(tp.Fields{ .kind = .dlstp, .size = 2, .rn = 12 }, d);
    const w = tp.fields(at(0x10, 0xF002, 0xC80F)).?;
    try std.testing.expectEqual(tp.Fields{ .kind = .wlstp, .size = 0, .rn = 2, .offset = 30 }, w);
    const w32 = tp.fields(at(0x14, 0xF020, 0xC80D)).?;
    try std.testing.expectEqual(@as(u32, 26), w32.offset);
    const l = tp.fields(at(0x1A, 0xF01F, 0xC80F)).?;
    try std.testing.expectEqual(tp.Fields{ .kind = .letp, .offset = 30 }, l);
    try std.testing.expectEqual(tp.Kind.lctp, tp.fields(at(0x2E, 0xF00F, 0xE001)).?.kind);
}

test "DLSTP loads LR and LTPSIZE and falls through" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.set(12, 10);
    try run(&cpu, at(0x08, 0xF02C, 0xE001));
    try std.testing.expectEqual(@as(u32, 10), cpu.regs.lr);
    try std.testing.expectEqual(@as(u3, 2), cpu.fp.fpscr.ltpsize);
    try std.testing.expectEqual(@as(u32, 0x0C), cpu.regs.pc);
    cpu.regs.set(1, 3);
    try run(&cpu, at(0x0C, 0xF031, 0xE001));
    try std.testing.expectEqual(@as(u3, 3), cpu.fp.fpscr.ltpsize);
}

test "WLSTP with a zero count skips the loop and keeps LR and LTPSIZE" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.lr = 0x99;
    try run(&cpu, at(0x10, 0xF002, 0xC80F));
    try std.testing.expectEqual(@as(u32, 0x32), cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0x99), cpu.regs.lr);
    try std.testing.expectEqual(@as(u3, 4), cpu.fp.fpscr.ltpsize);
}

test "WLSTP with a count enters the loop" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.set(2, 5);
    try run(&cpu, at(0x10, 0xF002, 0xC80F));
    try std.testing.expectEqual(@as(u32, 0x14), cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 5), cpu.regs.lr);
    try std.testing.expectEqual(@as(u3, 0), cpu.fp.fpscr.ltpsize);
}

test "LETP takes a vector off LR and branches back" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.fp.fpscr.ltpsize = 2;
    cpu.regs.lr = 10;
    try run(&cpu, at(0x1A, 0xF01F, 0xC80F));
    try std.testing.expectEqual(@as(u32, 0x00), cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 6), cpu.regs.lr);
    try std.testing.expectEqual(@as(u3, 2), cpu.fp.fpscr.ltpsize);
}

test "LETP on the last iteration falls through and resets LTPSIZE" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.fp.fpscr.ltpsize = 2;
    cpu.regs.lr = 3;
    try run(&cpu, at(0x1A, 0xF01F, 0xC80F));
    try std.testing.expectEqual(@as(u32, 0x1E), cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 3), cpu.regs.lr);
    try std.testing.expectEqual(@as(u3, 4), cpu.fp.fpscr.ltpsize);
}

test "LCTP resets LTPSIZE" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.fp.fpscr.ltpsize = 1;
    try run(&cpu, at(0x2E, 0xF00F, 0xE001));
    try std.testing.expectEqual(@as(u3, 4), cpu.fp.fpscr.ltpsize);
    try std.testing.expectEqual(@as(u32, 0x32), cpu.regs.pc);
}

test "SP, PC and the non-predicated loop forms are not claimed" {
    const refused = [_][2]u16{
        .{ 0xF02D, 0xE001 }, // DLSTP.32 with SP
        .{ 0xF01F, 0xE001 }, // DLSTP.16 with PC
        .{ 0xF00D, 0xC80F }, // WLSTP.8 with SP
        .{ 0xF00F, 0xC80F }, // LE
        .{ 0xF02F, 0xC80F }, // LE forever
        .{ 0xF040, 0xE001 }, // DLS
        .{ 0xF040, 0xC80F }, // WLS
    };
    for (refused) |e| try std.testing.expect(tp.fields(at(0, e[0], e[1])) == null);
}

test "the table routes the tail-predicated forms here and DLS to lob" {
    const mine = [_][2]u16{ .{ 0xF000, 0xE001 }, .{ 0xF013, 0xE001 }, .{ 0xF020, 0xC80D }, .{ 0xF01F, 0xC80F }, .{ 0xF00F, 0xE001 } };
    for (mine) |e| {
        const hit = decode.decode(at(0, e[0], e[1])) orelse return error.NotClaimed;
        try std.testing.expectEqualStrings("mve_lob_tp", hit.group);
    }
    const dls = decode.decode(at(0, 0xF040, 0xE001)) orelse return error.NotClaimed;
    try std.testing.expectEqualStrings("lob", dls.group);
}
