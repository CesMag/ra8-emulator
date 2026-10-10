//! Covers src/chip/core/cpu/ops/tt.zig and src/chip/core/cpu/sau_source.zig: TT on
//! the Zig core answers from the board's SAU.
const std = @import("std");
const ra8 = @import("ra8");
const ops_tt = ra8.chip.core.cpu.ops.tt;
const sau = ra8.chip.periph.sau;
const field = ra8.chip.core.csel.tt.field;
const fixture = @import("../exception/ram.zig");
const cpu_mod = ra8.chip.core.cpu.cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const SauSource = cpu_mod.sau_source.SauSource;

const both = field.r | field.rw;

/// Non-secure SRAM in region 0, a callable veneer page in region 1.
fn bootMap() sau.Sau {
    var unit = sau.Sau{ .ctrl = 1 };
    unit.table[0] = sau.Region.fromPair(0x3210_0000, 0x3217_FFE0 | 1);
    unit.table[1] = sau.Region.fromPair(0x0200_8000, 0x0200_8FE0 | 2 | 1);
    return unit;
}

/// TT r3, r0 (0xE840 0xF300), or TTA r3, r0 with `alternate`.
fn tt(alternate: bool) Instr {
    const second: u16 = if (alternate) 0xF380 else 0xF300;
    return .{ .address = fixture.base, .hw1 = 0xE840, .hw2 = second, .size = 4 };
}

fn run(cpu: *cpu_mod.Cpu, instr: Instr, target: u32) !u32 {
    cpu.regs.set(0, target);
    try ops_tt.group.decode(instr).?(cpu, instr);
    return cpu.regs.get(3);
}

test "TT claims the four T1 forms and nothing else" {
    try std.testing.expect(ops_tt.group.decode(tt(false)) != null);
    try std.testing.expect(ops_tt.group.decode(tt(true)) != null);
    try std.testing.expect(ops_tt.group.decode(.{ .address = 0, .hw1 = 0xE840, .hw2 = 0x3000, .size = 4 }) == null);
    try std.testing.expect(ops_tt.group.decode(.{ .address = 0, .hw1 = 0xE840, .size = 2 }) == null);
}

test "with no source TT answers every address Secure" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    try std.testing.expectEqual(both | field.s, try run(&cpu, tt(false), 0x3210_0040));
}

test "TT in Secure state reports the SAU region and the Non-secure bits" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    var unit = bootMap();
    var source = SauSource{ .unit = &unit };
    cpu.attribution = source.source();
    const ns = try run(&cpu, tt(true), 0x3210_0040);
    try std.testing.expectEqual(both | field.srvalid | field.nsr | field.nsrw, ns);
    const secure = try run(&cpu, tt(false), 0x2200_0000);
    try std.testing.expect(secure & field.s != 0);
    try std.testing.expect(secure & field.nsrw == 0);
    const veneer = try run(&cpu, tt(false), 0x0200_8010);
    try std.testing.expectEqual(@as(u32, 1), veneer >> field.sregion_shift & 0xFF);
}

test "TT in Non-secure state reports only the MPU half" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    var unit = bootMap();
    var source = SauSource{ .unit = &unit };
    cpu.attribution = source.source();
    cpu.banked.switchTo(&cpu.regs, .non_secure);
    try std.testing.expectEqual(both, try run(&cpu, tt(false), 0x3210_0040));
}

test "the SAU source attributes fetches the way SG and INVEP need" {
    var unit = bootMap();
    var source = SauSource{ .unit = &unit };
    const attr = source.source();
    try std.testing.expectEqual(cpu_mod.attribution.State.non_secure, attr.of(0x3210_0040));
    try std.testing.expectEqual(cpu_mod.attribution.State.callable, attr.of(0x0200_8010));
    try std.testing.expectEqual(cpu_mod.attribution.State.secure, attr.of(0x0200_0000));
}
