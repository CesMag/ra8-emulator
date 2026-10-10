//! Covers src/chip/core/cpu/ops/sg.zig and its SecureFault through Cpu.step.
const std = @import("std");
const ra8 = @import("ra8");
const sg = ra8.chip.core.cpu.ops.sg;
const fixture = @import("../exception/ram.zig");
const memmap = ra8.chip.core.memmap;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const Attribution = ra8.chip.core.cpu.cpu.attribution.Attribution;
const State = ra8.chip.core.cpu.cpu.attribution.State;

const secure_handler: u32 = fixture.base + 0x1C0;
const securefaultena: u32 = 1 << 19;
const sfsr: u32 = 0xE000_EDE4;
const invep: u32 = 1 << 0;
const ns_sp: u32 = fixture.base + 0x280;

/// Answers one state for every address.
const Fixed = struct {
    state: State,

    fn of(context: *anyopaque, address: u32) State {
        _ = address;
        const self: *Fixed = @ptrCast(@alignCast(context));
        return self.state;
    }

    fn source(self: *Fixed) Attribution {
        return .{ .context = self, .stateFn = of };
    }
};

fn at(address: u32) Instr {
    return .{ .address = address, .hw1 = sg.encoding, .hw2 = sg.encoding, .size = 4 };
}

/// A booted core in Non-secure state on its own stack, with `fixed` as the
/// attribution and an LR that has bit 0 set.
fn nonSecure(ram: *fixture.Ram, fixed: *Fixed) !Cpu {
    var cpu = try fixture.boot(ram);
    cpu.attribution = fixed.source();
    cpu.banked.switchTo(&cpu.regs, .non_secure);
    cpu.regs.setSp(ns_sp);
    cpu.regs.lr = fixture.handler | 1;
    return cpu;
}

fn run(cpu: *Cpu, instr: Instr) !void {
    try sg.group.decode(instr).?(cpu, instr);
}

test "SG claims only 0xE97F 0xE97F" {
    try std.testing.expect(sg.group.decode(at(0)) != null);
    try std.testing.expect(sg.group.decode(.{ .address = 0, .hw1 = 0xE97F, .hw2 = 0xE97E, .size = 4 }) == null);
    try std.testing.expect(sg.group.decode(.{ .address = 0, .hw1 = 0xE97F, .size = 2 }) == null);
}

test "SG in Secure state is a NOP" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    const sp = cpu.regs.sp();
    cpu.regs.lr = fixture.handler | 1;
    try run(&cpu, at(fixture.code));
    try std.testing.expectEqual(ra8.chip.core.banked.State.secure, cpu.banked.current);
    try std.testing.expectEqual(fixture.handler | 1, cpu.regs.lr);
    try std.testing.expectEqual(sp, cpu.regs.sp());
}

test "SG at a callable address makes a Non-secure core Secure and banks the stack" {
    var ram: fixture.Ram = .{};
    var fixed: Fixed = .{ .state = .callable };
    var cpu = try nonSecure(&ram, &fixed);
    try run(&cpu, at(fixture.code));
    try std.testing.expectEqual(ra8.chip.core.banked.State.secure, cpu.banked.current);
    // LR bit 0 clear, so BXNS LR goes back to Non-secure state.
    try std.testing.expectEqual(fixture.handler, cpu.regs.lr);
    // The Secure stack is back; the Non-secure one is parked in the bank.
    try std.testing.expectEqual(fixture.msp_top, cpu.regs.sp());
    try std.testing.expectEqual(ns_sp, cpu.banked.other.msp);
}

test "SG fetched from Non-secure memory by a Non-secure core is a NOP" {
    var ram: fixture.Ram = .{};
    var fixed: Fixed = .{ .state = .non_secure };
    var cpu = try nonSecure(&ram, &fixed);
    try run(&cpu, at(fixture.code));
    try std.testing.expectEqual(ra8.chip.core.banked.State.non_secure, cpu.banked.current);
    try std.testing.expectEqual(fixture.handler | 1, cpu.regs.lr);
    try std.testing.expectEqual(ns_sp, cpu.regs.sp());
}

test "SG fetched from Secure memory by a Non-secure core is refused" {
    var ram: fixture.Ram = .{};
    var fixed: Fixed = .{ .state = .secure };
    var cpu = try nonSecure(&ram, &fixed);
    try std.testing.expectError(error.InvalidEntry, run(&cpu, at(fixture.code)));
    try std.testing.expectEqual(ra8.chip.core.banked.State.non_secure, cpu.banked.current);
}

test "stepping SG outside NSC takes SecureFault INVEP on the SG itself" {
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.shcsr, securefaultena);
    ram.putWord(fixture.base + 7 * 4, secure_handler | 1);
    ram.putHalf(fixture.code, sg.encoding);
    ram.putHalf(fixture.code + 2, sg.encoding);
    var fixed: Fixed = .{ .state = .secure };
    var cpu = try nonSecure(&ram, &fixed);
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(secure_handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 7), cpu.regs.xpsr & 0x1FF);
    try std.testing.expectEqual(invep, ram.word(sfsr));
    // SecureFault is taken Secure (RA8EMU-168): the frame is on the
    // Non-secure stack, parked in the other bank.
    try std.testing.expectEqual(fixture.code, ram.word(cpu.banked.other.msp + 24));
}

test "SG leaves a Secure stack below its own limit alone (RA8EMU-395)" {
    var ram: fixture.Ram = .{};
    ram.putHalf(fixture.code, sg.encoding);
    ram.putHalf(fixture.code + 2, sg.encoding);
    var fixed: Fixed = .{ .state = .callable };
    var cpu = try nonSecure(&ram, &fixed);
    // A Secure PSP the gateway never touches, under a PSPLIM_S above it.
    cpu.banked.other.psp = fixture.base + 0x40;
    cpu.banked.other.psplim = fixture.base + 0x100;
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(ra8.chip.core.banked.State.secure, cpu.banked.current);
    try std.testing.expectEqual(fixture.code + 4, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.cfsr));
    try std.testing.expectEqual(ns_sp, cpu.banked.other.msp);
}
