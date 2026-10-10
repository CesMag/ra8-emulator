//! Covers src/chip/core/cpu/attribution.zig and the Non-secure fetch check
//! Cpu.step makes with it (RA8EMU-359).
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("exception/ram.zig");
const memmap = ra8.chip.core.memmap;
const attribution = ra8.chip.core.cpu.cpu.attribution;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const State = attribution.State;

const secure_handler: u32 = fixture.base + 0x1C0;
const securefaultena: u32 = 1 << 19;
const sfsr: u32 = 0xE000_EDE4;
const invep: u32 = 1 << 0;
const ns_sp: u32 = fixture.base + 0x280;
const sg: u16 = 0xE97F;
const nop: u16 = 0xBF00;

/// Answers one state for every address.
const Fixed = struct {
    state: State,

    fn of(context: *anyopaque, address: u32) State {
        _ = address;
        const self: *Fixed = @ptrCast(@alignCast(context));
        return self.state;
    }

    fn source(self: *Fixed) attribution.Attribution {
        return .{ .context = self, .stateFn = of };
    }
};

const wide_sg: Instr = .{ .address = 0, .hw1 = sg, .hw2 = sg, .size = 4 };
const narrow_nop: Instr = .{ .address = 0, .hw1 = nop, .size = 2 };

test "no source means every address is Secure and nothing is refused" {
    try std.testing.expectEqual(State.secure, attribution.state(null, 0x1000));
    try std.testing.expect(!attribution.refusesEntry(null, narrow_nop));
}

test "Secure memory refuses everything, NSC everything but SG, Non-secure nothing" {
    var fixed: Fixed = .{ .state = .secure };
    try std.testing.expect(attribution.refusesEntry(fixed.source(), wide_sg));
    try std.testing.expect(attribution.refusesEntry(fixed.source(), narrow_nop));
    fixed.state = .callable;
    try std.testing.expect(!attribution.refusesEntry(fixed.source(), wide_sg));
    try std.testing.expect(attribution.refusesEntry(fixed.source(), narrow_nop));
    fixed.state = .non_secure;
    try std.testing.expect(!attribution.refusesEntry(fixed.source(), narrow_nop));
}

/// A booted core in Non-secure state at fixture.code, with `fixed` as the
/// attribution, SecureFault enabled and a NOP at the PC.
fn nonSecure(ram: *fixture.Ram, fixed: *Fixed) !Cpu {
    ram.putWord(memmap.scb.shcsr, securefaultena);
    ram.putWord(fixture.base + 7 * 4, secure_handler | 1);
    ram.putHalf(fixture.code, nop);
    var cpu = try fixture.boot(ram);
    cpu.attribution = fixed.source();
    cpu.banked.switchTo(&cpu.regs, .non_secure);
    cpu.regs.setSp(ns_sp);
    return cpu;
}

fn expectInvep(ram: *fixture.Ram, cpu: *Cpu) !void {
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(secure_handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 7), cpu.regs.xpsr & 0x1FF);
    try std.testing.expectEqual(invep, ram.word(sfsr));
    // SecureFault is taken Secure (RA8EMU-168), so the frame holding the
    // refused instruction as its return address is on the Non-secure stack.
    try std.testing.expectEqual(.secure, cpu.banked.current);
    try std.testing.expectEqual(fixture.code, ram.word(cpu.banked.other.msp + 24));
    try std.testing.expectEqual(@as(u64, 0), cpu.retired);
}

test "a Non-secure branch into Secure code takes INVEP instead of running it" {
    var ram: fixture.Ram = .{};
    var fixed: Fixed = .{ .state = .secure };
    var cpu = try nonSecure(&ram, &fixed);
    try expectInvep(&ram, &cpu);
}

test "a Non-secure branch into NSC that lands on something other than SG takes INVEP" {
    var ram: fixture.Ram = .{};
    var fixed: Fixed = .{ .state = .callable };
    var cpu = try nonSecure(&ram, &fixed);
    try expectInvep(&ram, &cpu);
}

test "a Non-secure fetch from Non-secure memory runs as before" {
    var ram: fixture.Ram = .{};
    var fixed: Fixed = .{ .state = .non_secure };
    var cpu = try nonSecure(&ram, &fixed);
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(fixture.code + 2, cpu.regs.pc);
    try std.testing.expectEqual(@as(u64, 1), cpu.retired);
    try std.testing.expectEqual(@as(u32, 0), ram.word(sfsr));
}

test "a Secure core is never checked" {
    var ram: fixture.Ram = .{};
    var fixed: Fixed = .{ .state = .secure };
    var cpu = try nonSecure(&ram, &fixed);
    cpu.banked.switchTo(&cpu.regs, .secure);
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(fixture.code + 2, cpu.regs.pc);
}

const invtran: u32 = 1 << 4;

test "a Secure core fetching Non-secure memory takes INVTRAN instead of running it" {
    var ram: fixture.Ram = .{};
    var fixed: Fixed = .{ .state = .non_secure };
    var cpu = try nonSecure(&ram, &fixed);
    cpu.banked.switchTo(&cpu.regs, .secure);
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(secure_handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 7), cpu.regs.xpsr & 0x1FF);
    try std.testing.expectEqual(invtran, ram.word(sfsr));
    try std.testing.expectEqual(@as(u64, 0), cpu.retired);
}

test "INVTRAN never fires without a source, on exempt ranges, or from NSC" {
    var fixed: Fixed = .{ .state = .non_secure };
    try std.testing.expect(!attribution.refusesTransition(null, fixture.code));
    try std.testing.expect(!attribution.refusesTransition(fixed.source(), 0xE000_E000));
    try std.testing.expect(attribution.refusesTransition(fixed.source(), fixture.code));
    fixed.state = .callable;
    try std.testing.expect(!attribution.refusesTransition(fixed.source(), fixture.code));
}

test {
    _ = @import("sau_source_test.zig");
}
