//! Covers src/chip/core/cpu/exception/ret.zig, through whole instructions: SVC
//! into the handler and BX LR or POP {PC} back out.
const std = @import("std");
const ra8 = @import("ra8");
const regs = ra8.chip.core.cpu.regs;
const fixture = @import("ram.zig");

const svc: u16 = 0xDF00;
const bx_lr: u16 = 0x4770;
const pop_pc: u16 = 0xBD00;

fn program(ram: *fixture.Ram, handler: u16) void {
    ram.putHalf(fixture.code, svc);
    ram.putHalf(fixture.code + 2, 0xBF00); // nop
    ram.putHalf(fixture.handler, handler);
}

test "SVC then BX LR comes back to the next instruction with everything restored" {
    var ram: fixture.Ram = .{};
    program(&ram, bx_lr);
    var cpu = try fixture.boot(&ram);
    cpu.regs.low[2] = 0x22;
    cpu.regs.xpsr |= 0x2000_0000; // C
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(fixture.handler, cpu.regs.pc);
    try std.testing.expect(cpu.regs.handlerMode());
    cpu.regs.low[2] = 0xDEAD;
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(fixture.code + 2, cpu.regs.pc);
    try std.testing.expect(!cpu.regs.handlerMode());
    try std.testing.expectEqual(fixture.msp_top, cpu.regs.msp);
    try std.testing.expectEqual(@as(u32, 0x22), cpu.regs.low[2]);
    try std.testing.expectEqual(@as(u32, 0x2000_0000), cpu.regs.xpsr & 0xF800_0000);
    try std.testing.expectEqual(@as(?u32, null), cpu.regs.exc_return);
    try std.testing.expectEqual(@as(u64, 2), cpu.retired);
}

test "a realigned frame gives the stack back its odd word" {
    var ram: fixture.Ram = .{};
    program(&ram, bx_lr);
    var cpu = try fixture.boot(&ram);
    cpu.regs.msp = fixture.msp_top - 4;
    _ = cpu.step();
    try std.testing.expectEqual(fixture.msp_top - 0x28, cpu.regs.msp);
    _ = cpu.step();
    try std.testing.expectEqual(fixture.msp_top - 4, cpu.regs.msp);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.xpsr & (1 << 9));
}

test "a return to the PSP restores it and selects it again" {
    var ram: fixture.Ram = .{};
    program(&ram, bx_lr);
    var cpu = try fixture.boot(&ram);
    cpu.regs.psp = fixture.psp_top;
    cpu.regs.control |= regs.control_bits.spsel;
    _ = cpu.step();
    _ = cpu.step();
    try std.testing.expectEqual(fixture.psp_top, cpu.regs.psp);
    try std.testing.expect(cpu.regs.usesPsp());
    try std.testing.expectEqual(fixture.code + 2, cpu.regs.pc);
}

test "POP into the PC returns the same way" {
    var ram: fixture.Ram = .{};
    program(&ram, pop_pc);
    var cpu = try fixture.boot(&ram);
    _ = cpu.step();
    // The handler pushed LR; put it on the stack the way PUSH {LR} would.
    cpu.regs.msp -= 4;
    ram.putWord(cpu.regs.msp, cpu.regs.lr);
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(fixture.code + 2, cpu.regs.pc);
    try std.testing.expectEqual(fixture.msp_top, cpu.regs.msp);
}

const usage_handler: u32 = fixture.base + 0x1C0;

/// Return from the SVC handler to `value` and expect INVPC tail-chained.
fn expectInvpc(value: u32) !void {
    var ram: fixture.Ram = .{};
    program(&ram, bx_lr);
    ram.putWord(fixture.base + 6 * 4, usage_handler | 1);
    ram.putWord(ra8.chip.core.memmap.scb.shcsr, 1 << 18);
    var cpu = try fixture.boot(&ram);
    _ = cpu.step();
    const frame_at = cpu.regs.msp;
    cpu.regs.lr = value;
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(usage_handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 6), cpu.regs.xpsr & 0x1FF);
    try std.testing.expectEqual(@as(u32, 1 << 18), ram.word(ra8.chip.core.memmap.scb.cfsr));
    try std.testing.expectEqual(0xF000_0000 +% value, cpu.regs.lr);
    // No new frame: the refused one is still where the return found it.
    try std.testing.expectEqual(frame_at, cpu.regs.msp);
    try std.testing.expectEqual(@as(u9, 6), cpu.active.running().?.number);
}

test "an EXC_RETURN the core cannot honour tail-chains INVPC" {
    try expectInvpc(0xFFFF_FFF8); // Non-secure exception on a Secure stack: needs the callee frame
}

test "a frame whose IPSR contradicts the return mode tail-chains INVPC" {
    try expectInvpc(0xFFFF_FFF1); // Handler mode, but the frame came from Thread
}

test "a refused return with FAULTMASK set locks up and stops the core" {
    var ram: fixture.Ram = .{};
    program(&ram, bx_lr);
    var cpu = try fixture.boot(&ram);
    _ = cpu.step();
    cpu.regs.faultmask = 1;
    cpu.regs.lr = 0xFFFF_FFF8;
    try std.testing.expectEqual(fixture.handler, cpu.step().?.invalid_return);
}

test "a branch to 0xFFxxxxxx in Thread mode is a plain branch" {
    var regs_file: regs.Regs = .{};
    regs_file.bxWritePc(0xFFFF_FFF9);
    try std.testing.expectEqual(@as(?u32, null), regs_file.exc_return);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFF8), regs_file.pc);
}

test "an FP frame comes back with S0-S15, FPSCR and FPCA restored" {
    var ram: fixture.Ram = .{};
    program(&ram, bx_lr);
    var cpu = try fixture.boot(&ram);
    cpu.fp.context.fpccr.lspen = 0;
    cpu.regs.control |= regs.control_bits.fpca;
    for (0..16) |i| cpu.fp.bank.writeS(@intCast(i), 0x4000_0000 + @as(u32, @intCast(i)));
    cpu.fp.fpscr = ra8.chip.core.cpu.fpu.fpscr.Fpscr.fromBits(0x0300_0000);
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(fixture.msp_top - 0x68, cpu.regs.msp);
    // The handler clobbers the caller-saved FP registers.
    for (0..16) |i| cpu.fp.bank.writeS(@intCast(i), 0);
    cpu.fp.fpscr = ra8.chip.core.cpu.fpu.fpscr.Fpscr.fromBits(0);
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(fixture.code + 2, cpu.regs.pc);
    try std.testing.expectEqual(fixture.msp_top, cpu.regs.msp);
    try std.testing.expect(cpu.regs.control & regs.control_bits.fpca != 0);
    for (0..16) |i| try std.testing.expectEqual(0x4000_0000 + @as(u32, @intCast(i)), cpu.fp.bank.readS(@intCast(i)));
    try std.testing.expectEqual(@as(u32, 0x0300_0000), cpu.fp.fpscr.bits());
}

test "a basic-frame return leaves FPCA clear" {
    var ram: fixture.Ram = .{};
    program(&ram, bx_lr);
    var cpu = try fixture.boot(&ram);
    _ = cpu.step();
    _ = cpu.step();
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.control & regs.control_bits.fpca);
}

test "a Non-secure exception enters and returns without leaving its state" {
    var ram: fixture.Ram = .{};
    program(&ram, bx_lr);
    var cpu = try fixture.boot(&ram);
    cpu.banked.current = .non_secure;
    _ = cpu.step();
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFB8), cpu.regs.lr);
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(fixture.code + 2, cpu.regs.pc);
    try std.testing.expect(!cpu.regs.handlerMode());
    try std.testing.expectEqual(fixture.msp_top, cpu.regs.msp);
}

test "a Non-secure EXC_RETURN from Secure state is not a return the core takes" {
    var ram: fixture.Ram = .{};
    program(&ram, bx_lr);
    var cpu = try fixture.boot(&ram);
    _ = cpu.step();
    cpu.regs.lr = 0xFFFF_FFB8;
    _ = cpu.step();
    try std.testing.expect(cpu.regs.pc != fixture.code + 2);
    try std.testing.expect(cpu.regs.handlerMode());
}

test "a Non-secure handler returning to a Secure exception tail-chains SecureFault INVER" {
    var ram: fixture.Ram = .{};
    program(&ram, bx_lr);
    const secure_handler: u32 = fixture.base + 0x1E0;
    ram.putWord(fixture.base + 7 * 4, secure_handler | 1);
    ram.putWord(ra8.chip.core.memmap.scb.shcsr, 1 << 19);
    var cpu = try fixture.boot(&ram);
    cpu.banked.current = .non_secure;
    _ = cpu.step();
    const frame_at = cpu.regs.msp;
    const value: u32 = 0xFFFF_FFB9; // ES set: names a Secure exception
    cpu.regs.lr = value;
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(secure_handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 7), cpu.regs.xpsr & 0x1FF);
    try std.testing.expectEqual(@as(u32, 1 << 2), ram.word(0xE000_EDE4));
    try std.testing.expectEqual(0xF000_0000 +% value, cpu.regs.lr);
    try std.testing.expectEqual(.secure, cpu.banked.current);
    try std.testing.expectEqual(@as(u9, 7), cpu.active.running().?.number);
    try std.testing.expectEqual(@as(u32, 1), cpu.secure_faults);
    // No new frame: the refused one stays on the Non-secure stack.
    try std.testing.expectEqual(frame_at, cpu.banked.other.msp);
}
