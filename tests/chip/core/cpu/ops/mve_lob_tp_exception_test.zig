//! Covers src/chip/core/cpu/ops/mve_lob_tp.zig across exceptions (RA8EMU-238):
//! PendSV taken in the middle of a tail-predicated loop, with the loop
//! finishing afterwards on the right count and the right predicated
//! result. LR goes out in the frame and LTPSIZE in the FPSCR word, so both
//! come back on return. The listing comes from LLVM's assembler for
//! -mcpu=cortex-m85 with MVE:
//!
//!   0x100  dlstp.32 lr, r0
//!   0x104  vadd.i32 q0, q0, q1
//!   0x108  letp lr, 0x104
//!   0x10C  nop
//!
//! and the handler at 0x180 is either `nop; bx lr` or
//! `vadd.i32 q3, q3, q1; bx lr`.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const qreg = ra8.chip.core.cpu.mve.qreg;
const fixture = @import("../exception/ram.zig");
const Fake = @import("../exception/fake_source.zig").Fake;

const pendsv: u9 = 14;
const listing = [_]u16{ 0xF020, 0xE001, 0xEF20, 0x0842, 0xF01F, 0xC005, 0xBF00 };
const quiet_handler = [_]u16{ 0xBF00, 0x4770 };
const mve_handler = [_]u16{ 0xEF26, 0x6842, 0x4770 };
const ones: u128 = 0x0001_0001_0001_0001_0001_0001_0001_0001;
/// Ten words of ones added into Q0: lanes 0-1 three times, lanes 2-3 twice.
const ten_words: u128 = 0x0002_0002_0002_0002_0003_0003_0003_0003;

fn setup(ram: *fixture.Ram, fake: *Fake, handler: []const u16) !Cpu {
    for (listing, 0..) |half, i| ram.putHalf(fixture.code + @as(u32, @intCast(i)) * 2, half);
    for (handler, 0..) |half, i| ram.putHalf(fixture.handler + @as(u32, @intCast(i)) * 2, half);
    ram.putWord(fixture.base + 4 * @as(u32, pendsv), fixture.handler | 1);
    var cpu = try fixture.boot(ram);
    cpu.source = fake.source();
    qreg.write(&cpu.fp.bank, 1, ones);
    cpu.regs.set(0, 10);
    return cpu;
}

/// Runs one instruction at a time until PC reaches `pc`, or fails after
/// `limit` instructions.
fn runTo(cpu: *Cpu, pc: u32, limit: usize) !void {
    for (0..limit) |_| {
        if (cpu.regs.pc == pc) return;
        _ = cpu.run(1);
    }
    if (cpu.regs.pc != pc) return error.DidNotArrive;
}

fn expectFinished(cpu: *const Cpu, fake: *const Fake) !void {
    try std.testing.expectEqual(fixture.code + 0x0C, cpu.regs.pc);
    try std.testing.expectEqual(ten_words, qreg.read(&cpu.fp.bank, 0));
    try std.testing.expectEqual(@as(u32, 2), cpu.regs.lr);
    try std.testing.expectEqual(@as(u3, 4), cpu.fp.fpscr.ltpsize);
    try std.testing.expectEqual(@as(u32, 1), fake.taken);
    try std.testing.expectEqual(@as(?u9, pendsv), fake.last_returned);
    try std.testing.expect(!cpu.regs.handlerMode());
}

test "PendSV between the body and LETP on the first iteration" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{};
    var cpu = try setup(&ram, &fake, &quiet_handler);
    _ = cpu.run(2); // dlstp, vadd
    fake.pending = .{ .number = pendsv, .priority = 0xFF };
    _ = cpu.run(1); // taken, then the handler's NOP
    try std.testing.expect(cpu.regs.handlerMode());
    fake.pending = null;
    try std.testing.expectEqual(@as(u3, 2), cpu.fp.fpscr.ltpsize);
    _ = cpu.run(1); // BX LR back to the LETP
    try std.testing.expectEqual(fixture.code + 0x08, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 10), cpu.regs.lr);
    try runTo(&cpu, fixture.code + 0x0C, 8);
    try expectFinished(&cpu, &fake);
}

test "PendSV just before the last, masked iteration" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{};
    var cpu = try setup(&ram, &fake, &quiet_handler);
    _ = cpu.run(5); // dlstp, then two full iterations
    try std.testing.expectEqual(@as(u32, 2), cpu.regs.lr);
    fake.pending = .{ .number = pendsv, .priority = 0xFF };
    _ = cpu.run(1);
    fake.pending = null;
    _ = cpu.run(1);
    try std.testing.expectEqual(fixture.code + 0x04, cpu.regs.pc);
    try runTo(&cpu, fixture.code + 0x0C, 4);
    try expectFinished(&cpu, &fake);
}

test "a handler that runs MVE is not tail-predicated and leaves the loop intact" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{};
    var cpu = try setup(&ram, &fake, &mve_handler);
    _ = cpu.run(5);
    fake.pending = .{ .number = pendsv, .priority = 0xFF };
    _ = cpu.run(1); // taken, then the handler's VADD on a fresh FP context
    fake.pending = null;
    try std.testing.expectEqual(ones, qreg.read(&cpu.fp.bank, 3));
    _ = cpu.run(1); // BX LR
    try std.testing.expectEqual(@as(u128, 0), qreg.read(&cpu.fp.bank, 3));
    try runTo(&cpu, fixture.code + 0x0C, 4);
    try expectFinished(&cpu, &fake);
}
