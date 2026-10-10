//! An FP-using handler run end to end on the Zig core (RA8EMU-124): real
//! FP instructions in Thread mode open an FP context, SVC enters with the
//! extended frame, the handler's own FP instruction overwrites S0, and the
//! return restores it. There is no lockstep oracle for the
//! FType-clear EXC_RETURN, so this test is the check.
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("ram.zig");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;

const one: u32 = 0x3F80_0000; // 1.0
const three: u32 = 0x4040_0000; // 3.0
const exc_return_fp_thread_msp: u32 = 0xFFFF_FFE9;
const extended_frame: u32 = 0x68;

/// Thread: VMOV.F32 S0, #1.0; SVC #0; VMOV R6, S0; NOP.
/// Handler: VMOV.F32 S0, #3.0; VMOV R4, S0; BX LR. R4, since the return
/// restores R0-R3 from the frame.
fn setup(ram: *fixture.Ram) !Cpu {
    const thread = [_]u16{ 0xEEB7, 0x0A00, 0xDF00, 0xEE10, 0x6A10, 0xBF00, 0xBF00 };
    const handler = [_]u16{ 0xEEB0, 0x0A08, 0xEE10, 0x4A10, 0x4770 };
    for (thread, 0..) |hw, i| ram.putHalf(fixture.code + 2 * @as(u32, @intCast(i)), hw);
    for (handler, 0..) |hw, i| ram.putHalf(fixture.handler + 2 * @as(u32, @intCast(i)), hw);
    return fixture.boot(ram);
}

fn enter(cpu: *Cpu) !void {
    _ = cpu.run(2); // VMOV S0, then SVC is taken
    try std.testing.expectEqual(fixture.handler, cpu.regs.pc);
    try std.testing.expectEqual(exc_return_fp_thread_msp, cpu.regs.lr);
    try std.testing.expectEqual(fixture.msp_top - extended_frame, cpu.regs.sp());
}

fn finish(cpu: *Cpu) !void {
    _ = cpu.run(3); // the handler
    try std.testing.expectEqual(three, cpu.regs.get(4));
    _ = cpu.run(1); // VMOV R6, S0 back in Thread mode
    try std.testing.expect(!cpu.regs.handlerMode());
    try std.testing.expectEqual(one, cpu.regs.get(6));
    try std.testing.expectEqual(fixture.msp_top, cpu.regs.sp());
}

test "with FPCCR at reset the handler's FP write is undone by the return" {
    var ram: fixture.Ram = .{};
    var cpu = try setup(&ram);
    try enter(&cpu);
    // Lazy entry: S0 waits in the registers, not the frame.
    try std.testing.expectEqual(@as(u1, 1), cpu.fp.context.fpccr.lspact);
    try std.testing.expectEqual(@as(u32, 0), ram.word(cpu.regs.sp() + 0x20));
    _ = cpu.run(1); // the handler's VMOV triggers the lazy push first
    try std.testing.expectEqual(@as(u1, 0), cpu.fp.context.fpccr.lspact);
    try std.testing.expectEqual(one, ram.word(cpu.regs.sp() + 0x20));
    cpu.regs.pc = fixture.handler; // replay the handler from its start
    try finish(&cpu);
    try std.testing.expectEqual(@as(u1, 0), cpu.fp.context.fpccr.lspact);
}

test "lazy stacking never triggers when the handler runs no FP op" {
    var ram: fixture.Ram = .{};
    var cpu = try setup(&ram);
    ram.putHalf(fixture.handler, 0x2403); // movs r4, #3
    ram.putHalf(fixture.handler + 2, 0x4770); // bx lr
    try enter(&cpu);
    const frame_at = cpu.regs.sp();
    _ = cpu.run(2); // the handler and its return
    try std.testing.expect(!cpu.regs.handlerMode());
    try std.testing.expectEqual(@as(u1, 0), cpu.fp.context.fpccr.lspact);
    try std.testing.expectEqual(@as(u32, 0), ram.word(frame_at + 0x20));
    _ = cpu.run(1); // VMOV R6, S0 back in Thread mode
    try std.testing.expectEqual(one, cpu.regs.get(6));
    try std.testing.expectEqual(fixture.msp_top, cpu.regs.sp());
}

test "eager stacking: S0 is in the frame before the handler runs" {
    var ram: fixture.Ram = .{};
    var cpu = try setup(&ram);
    cpu.fp.context.fpccr.lspen = 0;
    try enter(&cpu);
    try std.testing.expectEqual(one, ram.word(cpu.regs.sp() + 0x20));
    try finish(&cpu);
}

test "without an FP context the handler gets the basic frame" {
    var ram: fixture.Ram = .{};
    var cpu = try setup(&ram);
    cpu.regs.pc = fixture.code + 4; // skip the VMOV: no FP context opens
    _ = cpu.run(1);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFF9), cpu.regs.lr);
    try std.testing.expectEqual(fixture.msp_top - 0x20, cpu.regs.sp());
}

const vpr_word: u32 = 0x0084_1234; // P0 0x1234, MASK01 0x4, MASK23 0x8

test "with MVE, VPR is stacked at +0x64 and the return restores it" {
    var ram: fixture.Ram = .{};
    var cpu = try setup(&ram);
    cpu.fp.context.fpccr.lspen = 0;
    _ = cpu.run(1); // open the Secure FP context before seeding VPR
    cpu.fp.vpr = @bitCast(vpr_word);
    _ = cpu.run(1); // SVC stacks the active Secure context
    try std.testing.expectEqual(fixture.handler, cpu.regs.pc);
    try std.testing.expectEqual(vpr_word, ram.word(cpu.regs.sp() + 0x64));
    cpu.fp.vpr = .{}; // the handler's own predication
    ram.putWord(cpu.regs.sp() + 0x64, vpr_word | 0xFF00_0000);
    try finish(&cpu);
    try std.testing.expectEqual(vpr_word, @as(u32, @bitCast(cpu.fp.vpr)));
}

test "without MVE the VPR word is stacked as 0 and ignored on return" {
    var ram: fixture.Ram = .{};
    var cpu = try setup(&ram);
    cpu.profile = .m33;
    cpu.fp.context.fpccr.lspen = 0;
    _ = cpu.run(1); // open the Secure FP context before seeding VPR
    cpu.fp.vpr = @bitCast(vpr_word);
    _ = cpu.run(1); // SVC stacks the active Secure context
    try std.testing.expectEqual(fixture.handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0), ram.word(cpu.regs.sp() + 0x64));
    cpu.fp.vpr = .{};
    ram.putWord(cpu.regs.sp() + 0x64, vpr_word);
    try finish(&cpu);
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(cpu.fp.vpr)));
}
