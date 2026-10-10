//! Covers src/chip/core/cpu/ops/blxns.zig.
const std = @import("std");
const ra8 = @import("ra8");
const blxns = ra8.chip.core.cpu.ops.blxns;
const fixture = @import("../exception/ram.zig");
const sfpa: u32 = 1 << 3;

fn claims(hw1: u16) bool {
    return blxns.group.decode(.{ .address = 0, .hw1 = hw1, .size = 2 }) != null;
}

test "BLXNS claims every low and high Rm but SP and PC, and leaves BXNS and BLX" {
    try std.testing.expect(claims(0x4784)); // blxns r0
    try std.testing.expect(claims(0x47E4)); // blxns r12
    try std.testing.expect(claims(0x47F4)); // blxns lr
    try std.testing.expect(!claims(0x47EC)); // blxns sp
    try std.testing.expect(!claims(0x47FC)); // blxns pc
    try std.testing.expect(!claims(0x4704)); // bxns r0
    try std.testing.expect(!claims(0x4780)); // blx r0
    try std.testing.expect(blxns.group.decode(.{ .address = 0, .hw1 = 0x4784, .hw2 = 0, .size = 4 }) == null);
}

fn callNs(cpu: *ra8.chip.core.cpu.cpu.Cpu) !void {
    cpu.regs.low[0] = fixture.handler; // bit 0 clear, as the firmware passes it
    const instr: ra8.chip.core.cpu.instr.Instr = .{ .address = fixture.code, .hw1 = 0x4784, .size = 2 };
    try blxns.group.decode(instr).?(cpu, instr);
}

test "BLXNS r0 pushes the return frame, becomes Non-secure and leaves FNC_RETURN in LR" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    const sp = cpu.regs.sp();
    try callNs(&cpu);
    try std.testing.expectEqual(fixture.handler, cpu.regs.pc);
    try std.testing.expectEqual(blxns.fnc_return, cpu.regs.lr);
    try std.testing.expectEqual(ra8.chip.core.banked.State.non_secure, cpu.banked.current);
    try std.testing.expectEqual(sp - 8, cpu.banked.other.msp); // the frame stays on the Secure stack
    try std.testing.expectEqual(fixture.code + 2 | 1, ram.word(sp - 8));
    try std.testing.expectEqual(@as(u32, 0), ram.word(sp - 4)); // Thread mode, SFPA clear
}

test "from Handler mode the frame keeps IPSR and SFPA, IPSR reads 1 and SFPA clears" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    const sp = cpu.regs.sp();
    cpu.regs.xpsr |= 11;
    cpu.regs.control |= sfpa;
    try callNs(&cpu);
    try std.testing.expectEqual(11 | blxns.retpsr_sfpa, ram.word(sp - 4));
    try std.testing.expectEqual(@as(u32, 1), cpu.regs.xpsr & 0x1FF);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.control & sfpa);
}

test "a frame below MSPLIM is a stack overflow and changes nothing" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    const sp = cpu.regs.sp();
    cpu.regs.msplim = sp - 4;
    cpu.regs.low[0] = fixture.handler;
    const instr: ra8.chip.core.cpu.instr.Instr = .{ .address = fixture.code, .hw1 = 0x4784, .size = 2 };
    try std.testing.expectError(error.StackOverflow, blxns.group.decode(instr).?(&cpu, instr));
    try std.testing.expectEqual(ra8.chip.core.banked.State.secure, cpu.banked.current);
    try std.testing.expectEqual(sp, cpu.regs.sp());
    try std.testing.expectEqual(@as(u32, 0), ram.word(sp - 8));
}

test "BLXNS to a target with bit 0 set is a BLX and stays Secure" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    const sp = cpu.regs.sp();
    cpu.regs.low[0] = fixture.handler | 1;
    const instr: ra8.chip.core.cpu.instr.Instr = .{ .address = fixture.code, .hw1 = 0x4784, .size = 2 };
    try blxns.group.decode(instr).?(&cpu, instr);
    try std.testing.expectEqual(fixture.handler, cpu.regs.pc);
    try std.testing.expectEqual(ra8.chip.core.banked.State.secure, cpu.banked.current);
    try std.testing.expectEqual(sp, cpu.regs.sp()); // VTOR_NS unreadable here
}

test "no Non-secure stack when VTOR_NS cannot be read" {
    var ram: fixture.Ram = .{};
    const cpu = try fixture.boot(&ram);
    try std.testing.expectEqual(@as(?u32, null), blxns.nonSecureStack(&cpu));
}

test "BLXNS has no lockstep oracle" {
    try std.testing.expect(!blxns.group.oracle);
}

// Ported from tests/chip/core/tz_test.zig (the old seam's decode), run
// against the core's group (RA8EMU-252). The seam decodes SP and PC too;
// the core leaves those UNPREDICTABLE forms unclaimed.

test "seam port: blxns r2, the one the RA8D2 secure boot issues, is claimed" {
    try std.testing.expect(claims(0x4794));
}

test "seam port: every Rm but SP and PC is claimed" {
    var rm: u16 = 0;
    while (rm < 15) : (rm += 1) {
        const hw1: u16 = 0x4780 | (rm << 3) | 0x04;
        try std.testing.expectEqual(rm != 13, claims(hw1));
    }
}

test "seam port: a plain BLX and unrelated halfwords are not BLXNS" {
    for ([_]u16{ 0x4790, 0xB580, 0x0000, 0xE002 }) |hw1| try std.testing.expect(!claims(hw1));
}
