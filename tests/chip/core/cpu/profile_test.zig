//! Covers src/chip/core/cpu/profile.zig: the per-CPU feature profile, through
//! decode.decodeFor and Cpu.step (RA8EMU-233).
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("exception/ram.zig");
const decode = ra8.chip.core.cpu.decode;
const Profile = decode.profile.Profile;
const Instr = ra8.chip.core.cpu.instr.Instr;
const memmap = ra8.chip.core.memmap;

const usage_handler: u32 = fixture.base + 0x1C0;
const usgfaultena: u32 = 1 << 18;
const undefinstr_bit: u32 = 1 << 16;

/// One Armv8.1-M encoding from each group the M33 lacks.
const vadd_i32 = [2]u16{ 0xEF22, 0x0844 };
const le_back = [2]u16{ 0xF00F, 0xC007 };
const lsll = [2]u16{ 0xEA52, 0x134F };
const armv8_1m_only = [_][2]u16{ vadd_i32, le_back, lsll };

fn wide(hw: [2]u16) Instr {
    return .{ .address = fixture.code, .hw1 = hw[0], .hw2 = hw[1], .size = 4 };
}

test "the M85 profile has every feature and the M33 profile none of the Armv8.1-M ones" {
    for (std.enums.values(decode.profile.Feature)) |feature| {
        try std.testing.expect(Profile.m85.has(feature));
    }
    try std.testing.expect(Profile.m33.has(.base));
    try std.testing.expect(!Profile.m33.has(.v8_1m));
    try std.testing.expect(!Profile.m33.has(.mve));
    try std.testing.expect(!Profile.m33.has(.lob));
}

test "the M85 decodes an MVE op, an LE and an LSLL, and the M33 refuses each" {
    for (armv8_1m_only) |hw| {
        try std.testing.expect(decode.decodeFor(Profile.m85, wide(hw)) != null);
        try std.testing.expect(decode.decodeFor(Profile.m33, wide(hw)) == null);
        try std.testing.expect(decode.refused(Profile.m33, wide(hw)));
        try std.testing.expect(!decode.refused(Profile.m85, wide(hw)));
    }
}

test "both profiles decode an Armv8.0-M encoding alike" {
    const nop_w = wide(.{ 0xF3AF, 0x8000 });
    try std.testing.expectEqualStrings(decode.decodeFor(Profile.m85, nop_w).?.group, decode.decodeFor(Profile.m33, nop_w).?.group);
    try std.testing.expect(!decode.refused(Profile.m33, nop_w));
}

test "an encoding no profile decodes is not a refusal" {
    try std.testing.expect(!decode.refused(Profile.m33, .{ .address = 0, .hw1 = 0xDE00, .size = 2 }));
}

test "the decode cache keeps to the profile it is asked for" {
    var cache: decode.cache.DecodeCache = .{};
    try std.testing.expect(cache.findFor(Profile.m33, wide(lsll)) == null);
    try std.testing.expect(cache.findFor(Profile.m85, wide(lsll)) != null);
}

fn stepOn(core: Profile, hw: [2]u16, ram: *fixture.Ram) !ra8.chip.core.cpu.cpu.Cpu {
    ram.putWord(fixture.base + 6 * 4, usage_handler | 1);
    ram.putWord(memmap.scb.shcsr, usgfaultena);
    ram.putHalf(fixture.code, hw[0]);
    ram.putHalf(fixture.code + 2, hw[1]);
    var cpu = try fixture.boot(ram);
    cpu.profile = core;
    return cpu;
}

test "on the M33 profile each Armv8.1-M encoding takes UsageFault UNDEFINSTR" {
    for (armv8_1m_only) |hw| {
        var ram: fixture.Ram = .{};
        var cpu = try stepOn(Profile.m33, hw, &ram);
        try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
        try std.testing.expectEqual(usage_handler, cpu.regs.pc);
        try std.testing.expectEqual(@as(u32, 6), cpu.regs.xpsr & 0x1FF);
        try std.testing.expectEqual(undefinstr_bit, ram.word(memmap.scb.cfsr));
        // The refused instruction is the stacked return address.
        try std.testing.expectEqual(fixture.code, ram.word(cpu.regs.sp() + 24));
    }
}

test "on the M85 profile the same encodings run" {
    for (armv8_1m_only) |hw| {
        var ram: fixture.Ram = .{};
        var cpu = try stepOn(Profile.m85, hw, &ram);
        _ = cpu.step();
        try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.cfsr) & undefinstr_bit);
        try std.testing.expect(cpu.regs.pc != usage_handler);
    }
}
