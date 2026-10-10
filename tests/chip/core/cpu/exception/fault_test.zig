//! Covers src/chip/core/cpu/exception/fault.zig through Cpu.step.
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("ram.zig");
const memmap = ra8.chip.core.memmap;

const usage_handler: u32 = fixture.base + 0x1C0;
const hard_handler: u32 = fixture.base + 0x1E0;
const threadx_usage_handler: u32 = fixture.base + 0x180;
const usgfaultena: u32 = 1 << 18;
const unaligned_bit: u32 = 1 << 24;
const invstate_bit: u32 = 1 << 17;
const nocp_bit: u32 = 1 << 19;
const stkof_bit: u32 = 1 << 20;
const divbyzero_bit: u32 = 1 << 25;
const div_0_trp: u32 = 1 << 4;
const forced: u32 = 1 << 30;
const threadx_current_ptr: u32 = fixture.base + 0x60;
const threadx_thread: u32 = fixture.base + 0x80;
const threadx_error_seen: u32 = fixture.base + 0x64;

/// The port's UsageFault_Handler through its call to
/// _tx_thread_stack_error_handler, followed by a callback stub that records
/// the TX_THREAD pointer. Halfwords and literal words come from assembling
/// tx_initialize_low_level.S's handler body with its external calls resolved.
fn putThreadxUsageHandler(ram: *fixture.Ram) void {
    const code = [_]u16{
        0xB672, 0x480E, 0x6801, 0xF411, 0x1F80, 0xD012, 0x6001, 0x480C,
        0x6800, 0xB501, 0xF000, 0xF80E, 0xE8BD, 0x4001, 0x2100, 0x4808,
        0x6001, 0x4808, 0xF04F, 0x5180, 0x6001, 0xF3BF, 0x8F4F, 0xB662,
        0x4770, 0xE7FE, 0x4904, 0x6008, 0x4770, 0x0000,
    };
    for (code, 0..) |half, i| ram.putHalf(threadx_usage_handler + @as(u32, @intCast(i * 2)), half);
    ram.putWord(threadx_usage_handler + 60, 0xE000_ED28);
    ram.putWord(threadx_usage_handler + 64, threadx_current_ptr);
    ram.putWord(threadx_usage_handler + 68, 0xE000_ED04);
    ram.putWord(threadx_usage_handler + 72, threadx_error_seen);
}

/// `ldm r0!, {r1, r2}` at the reset PC with r0 one byte off a word.
fn faulting(ram: *fixture.Ram) !ra8.chip.core.cpu.cpu.Cpu {
    ram.putWord(fixture.base + 3 * 4, hard_handler | 1);
    ram.putWord(fixture.base + 6 * 4, usage_handler | 1);
    ram.putWord(fixture.code, 0x0000_C806);
    var cpu = try fixture.boot(ram);
    cpu.regs.low[0] = fixture.base + 0x201;
    return cpu;
}

fn ipsr(cpu: *const ra8.chip.core.cpu.cpu.Cpu) u32 {
    return cpu.regs.xpsr & 0x1FF;
}

test "an unaligned access is taken as UsageFault when USGFAULTENA is set" {
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.shcsr, usgfaultena);
    var cpu = try faulting(&ram);
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(usage_handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 6), ipsr(&cpu));
    try std.testing.expectEqual(unaligned_bit, ram.word(memmap.scb.cfsr));
    try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.hfsr));
    // The faulting instruction is the stacked return address.
    try std.testing.expectEqual(fixture.code, ram.word(cpu.regs.sp() + 24));
    try std.testing.expectEqual(fixture.base + 0x201, cpu.regs.low[0]);
}

test "an unaligned MVE load sets CFSR.UNALIGNED on the Zig core" {
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.shcsr, usgfaultena);
    ram.putHalf(fixture.code, 0xECB1); // vldrw.u32 q7, [r1], #8
    ram.putHalf(fixture.code + 2, 0xFF02);
    ram.putWord(fixture.base + 6 * 4, usage_handler | 1);
    var cpu = try fixture.boot(&ram);
    cpu.regs.low[1] = fixture.base + 0x202;

    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(usage_handler, cpu.regs.pc);
    try std.testing.expectEqual(unaligned_bit, ram.word(memmap.scb.cfsr));
}

test "with USGFAULTENA clear it escalates to HardFault and sets HFSR.FORCED" {
    var ram: fixture.Ram = .{};
    var cpu = try faulting(&ram);
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(hard_handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 3), ipsr(&cpu));
    try std.testing.expectEqual(unaligned_bit, ram.word(memmap.scb.cfsr));
    try std.testing.expectEqual(forced, ram.word(memmap.scb.hfsr));
}

fn stackOverrun(ram: *fixture.Ram, psp: bool, first: u16, second: ?u16) !ra8.chip.core.cpu.cpu.Cpu {
    ram.putWord(fixture.base + 6 * 4, usage_handler | 1);
    ram.putWord(memmap.scb.shcsr, usgfaultena);
    ram.putHalf(fixture.code, first);
    if (second) |hw2| ram.putHalf(fixture.code + 2, hw2);
    var cpu = try fixture.boot(ram);
    if (psp) {
        cpu.regs.control |= ra8.chip.core.cpu.regs.control_bits.spsel;
        cpu.regs.psp = fixture.psp_top;
        cpu.regs.psplim = fixture.psp_top;
    } else {
        cpu.regs.msplim = fixture.msp_top;
    }
    cpu.regs.low[0] = if (psp) fixture.psp_top - 4 else fixture.msp_top - 4;
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(usage_handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 6), ipsr(&cpu));
    try std.testing.expectEqual(stkof_bit, ram.word(memmap.scb.cfsr));
    const frame_sp = if (psp) cpu.regs.psp else cpu.regs.sp();
    try std.testing.expectEqual(if (psp) fixture.psp_top else fixture.msp_top, frame_sp);
    return cpu;
}

test "PUSH crossing MSPLIM raises STKOF" {
    var ram: fixture.Ram = .{};
    _ = try stackOverrun(&ram, false, 0xB401, null); // push {r0}
}

test "PUSH crossing PSPLIM raises STKOF" {
    var ram: fixture.Ram = .{};
    _ = try stackOverrun(&ram, true, 0xB401, null); // push {r0}
}

test "ThreadX PSPLIM overflow reaches the port stack-error callback on Zig" {
    var ram: fixture.Ram = .{};
    const stack_start = fixture.psp_top - 16;
    ram.putWord(fixture.base + 6 * 4, threadx_usage_handler | 1);
    ram.putWord(memmap.scb.shcsr, usgfaultena);
    ram.putWord(threadx_current_ptr, threadx_thread);
    ram.putHalf(fixture.code, 0xF38C); // msr psplim, r12: ThreadX scheduler
    ram.putHalf(fixture.code + 2, 0x880B);
    ram.putHalf(fixture.code + 4, 0xF38C); // msr psp, r12: restore the thread
    ram.putHalf(fixture.code + 6, 0x8809);
    ram.putHalf(fixture.code + 8, 0xB401); // push {r0} crosses stack_start
    putThreadxUsageHandler(&ram);

    var cpu = try fixture.boot(&ram);
    cpu.regs.control |= ra8.chip.core.cpu.regs.control_bits.spsel;
    cpu.regs.low[12] = stack_start;
    cpu.regs.low[0] = 0xA5A5_5A5A;

    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(stack_start, cpu.regs.psplim);
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(stack_start, cpu.regs.psp);
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(threadx_usage_handler, cpu.regs.pc);
    try std.testing.expectEqual(stack_start, cpu.regs.psp);
    // The RAM-backed SCS does not model the W1C clear of CFSR.
    try std.testing.expectEqual(stkof_bit, ram.word(memmap.scb.cfsr));

    for (0..32) |_| {
        if (ram.word(threadx_error_seen) != 0) break;
        try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    }
    try std.testing.expectEqual(threadx_thread, ram.word(threadx_error_seen));
    try std.testing.expectEqual(@as(u32, 6), ipsr(&cpu));
}

test "MSR MSP crossing MSPLIM raises STKOF" {
    var ram: fixture.Ram = .{};
    _ = try stackOverrun(&ram, false, 0xF380, 0x8808); // msr msp, r0
}

test "MSR PSP crossing PSPLIM raises STKOF" {
    var ram: fixture.Ram = .{};
    _ = try stackOverrun(&ram, true, 0xF380, 0x8809); // msr psp, r0
}

test "SUB SP crossing MSPLIM raises STKOF" {
    var ram: fixture.Ram = .{};
    _ = try stackOverrun(&ram, false, 0xB082, null); // sub sp, #8
}

test "SUB SP crossing PSPLIM raises STKOF" {
    var ram: fixture.Ram = .{};
    _ = try stackOverrun(&ram, true, 0xB082, null); // sub sp, #8
}

test "PUSH that stays above MSPLIM retires normally" {
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.shcsr, usgfaultena);
    ram.putHalf(fixture.code, 0xB401); // push {r0}
    var cpu = try fixture.boot(&ram);
    cpu.regs.msplim = fixture.msp_top - 16;
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(fixture.code + 2, cpu.regs.pc);
    try std.testing.expectEqual(fixture.msp_top - 4, cpu.regs.msp);
    try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.cfsr));
}

test "EPSR.T clear raises INVSTATE" {
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.shcsr, usgfaultena);
    var cpu = try faulting(&ram);
    cpu.regs.xpsr &= ~ra8.chip.core.cpu.regs.xpsr_bits.thumb;
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(usage_handler, cpu.regs.pc);
    try std.testing.expectEqual(invstate_bit, ram.word(memmap.scb.cfsr));
}

test "a fault with FAULTMASK set locks up and stops instead" {
    var ram: fixture.Ram = .{};
    var cpu = try faulting(&ram);
    cpu.regs.faultmask = 1;
    try std.testing.expectEqual(fixture.code, cpu.step().?.unaligned);
    try std.testing.expectEqual(fixture.code, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.cfsr));
}

test "a fault inside HardFault locks up" {
    var ram: fixture.Ram = .{};
    var cpu = try faulting(&ram);
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    ram.putWord(hard_handler, 0x0000_C806);
    try std.testing.expectEqual(hard_handler, cpu.step().?.unaligned);
}

test "a blx through a null function pointer is taken as INVSTATE at address zero" {
    // RA8EMU-121: an old usb_selftest_cdc build left its GOT out of the .data
    // copy, so `blx r4` ran with r4 = 0 and landed with EPSR.T clear.
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.shcsr, usgfaultena);
    ram.putWord(fixture.base + 6 * 4, usage_handler | 1);
    ram.putWord(fixture.code, 0x0000_47A0);
    var cpu = try fixture.boot(&ram);
    cpu.regs.low[4] = 0;
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.pc);
    try std.testing.expectEqual((fixture.code + 2) | 1, cpu.regs.lr);
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(usage_handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 6), ipsr(&cpu));
    try std.testing.expectEqual(invstate_bit, ram.word(memmap.scb.cfsr));
    // The stacked return address is the even target the branch landed on.
    try std.testing.expectEqual(@as(u32, 0), ram.word(cpu.regs.sp() + 24));
}

fn divideCpu(ram: *fixture.Ram, hw1: u16, ccr: u32, shcsr: u32) !ra8.chip.core.cpu.cpu.Cpu {
    ram.putWord(fixture.base + 3 * 4, hard_handler | 1);
    ram.putWord(fixture.base + 6 * 4, usage_handler | 1);
    ram.putHalf(fixture.code, hw1);
    ram.putHalf(fixture.code + 2, 0xF2F1); // Rd=r2, Rm=r1
    ram.putWord(memmap.scb.ccr, ccr);
    ram.putWord(memmap.scb.shcsr, shcsr);
    var cpu = try fixture.boot(ram);
    cpu.regs.low[0] = 100;
    cpu.regs.low[1] = 0;
    return cpu;
}

test "SDIV and UDIV zero traps enter UsageFault and latch DIVBYZERO" {
    for ([_]u16{ 0xFB90, 0xFBB0 }) |hw1| {
        var ram: fixture.Ram = .{};
        var cpu = try divideCpu(&ram, hw1, div_0_trp, usgfaultena);
        try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
        try std.testing.expectEqual(usage_handler, cpu.regs.pc);
        try std.testing.expectEqual(@as(u32, 6), ipsr(&cpu));
        try std.testing.expectEqual(divbyzero_bit, ram.word(memmap.scb.cfsr));
        try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.hfsr));
        try std.testing.expectEqual(fixture.code, ram.word(cpu.regs.sp() + 24));
    }
}

test "a disabled UsageFault escalates divide zero to forced HardFault" {
    var ram: fixture.Ram = .{};
    var cpu = try divideCpu(&ram, 0xFBB0, div_0_trp, 0);
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(hard_handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 3), ipsr(&cpu));
    try std.testing.expectEqual(divbyzero_bit, ram.word(memmap.scb.cfsr));
    try std.testing.expectEqual(forced, ram.word(memmap.scb.hfsr));
}

test "DIV_0_TRP clear leaves the zero quotient unchanged" {
    var ram: fixture.Ram = .{};
    var cpu = try divideCpu(&ram, 0xFBB0, 0, usgfaultena);
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.low[2]);
    try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.cfsr));
}

test "a refused coprocessor op latches NOCP and runs the UsageFault handler" {
    var ram: fixture.Ram = .{};
    ram.putWord(fixture.base + 6 * 4, usage_handler | 1);
    ram.putWord(memmap.scb.shcsr, usgfaultena);
    ram.putHalf(fixture.code, 0xEC20); // vlstm r0
    ram.putHalf(fixture.code + 2, 0x0A00);
    ram.putHalf(usage_handler, 0x202A); // movs r0, #42
    var cpu = try fixture.boot(&ram);
    cpu.fp.cpacr = 0;
    cpu.regs.control |= ra8.chip.core.cpu.regs.control_bits.sfpa;

    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(usage_handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 6), ipsr(&cpu));
    try std.testing.expectEqual(nocp_bit, ram.word(memmap.scb.cfsr));
    try std.testing.expectEqual(fixture.code, ram.word(cpu.regs.sp() + 24));

    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(@as(u32, 42), cpu.regs.low[0]);
    try std.testing.expectEqual(usage_handler + 2, cpu.regs.pc);
}
