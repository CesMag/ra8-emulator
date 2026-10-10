//! Checks one printer over every encoding its decode group claims, at a fixed
//! address, against the digest its sweep reached when every encoding printed
//! as the reference disassembler did (tests/chip/core/cpu/text/digest.zig).
const std = @import("std");
const ra8 = @import("ra8");
const decode = ra8.chip.core.cpu.decode;
const Instr = ra8.chip.core.cpu.instr.Instr;
const digest = @import("digest.zig");

pub const address: u32 = 0x0200_0100;

pub fn expectGroupMatches(group: []const u8) !void {
    try expectGroupMatchesExcept(group, &.{});
}

/// As expectGroupMatches, skipping the encodings in `skip`: ones the
/// reference disassembler could not decode, which a by-name test covers instead.
pub fn expectGroupMatchesExcept(group: []const u8, skip: []const u16) !void {
    var sweep: digest.Sweep = .{};
    var hw: u32 = 0;
    while (hw <= 0xFFFF) : (hw += 1) {
        const hw1: u16 = @intCast(hw);
        if (Instr.isWide(hw1)) continue;
        if (std.mem.indexOfScalar(u16, skip, hw1) != null) continue;
        const instr: Instr = .{ .address = address, .hw1 = hw1, .size = 2 };
        const hit = decode.decode(instr) orelse continue;
        if (!std.mem.eql(u8, hit.group, group)) continue;
        sweep.add(instr);
    }
    try digest.expectFixture(group, digest.callKey(false, group, 0, 0, skip), &sweep);
}

/// The 32-bit form: every hw1 with `hw1 & mask == value`, each paired with
/// every hw2 in `samples`.
pub fn expectWideGroupMatches(group: []const u8, mask: u16, value: u16, samples: []const u16) !void {
    var sweep: digest.Sweep = .{};
    var hw: u32 = value;
    while (hw <= 0xFFFF) : (hw += 1) {
        const hw1: u16 = @intCast(hw);
        if (hw1 & mask != value) continue;
        for (samples) |hw2| {
            const instr: Instr = .{ .address = address, .hw1 = hw1, .hw2 = hw2, .size = 4 };
            const hit = decode.decode(instr) orelse continue;
            if (!std.mem.eql(u8, hit.group, group)) continue;
            sweep.add(instr);
        }
    }
    try digest.expectFixture(group, digest.callKey(true, group, mask, value, samples), &sweep);
}
