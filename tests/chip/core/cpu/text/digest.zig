//! A running digest of one printer sweep: every encoding a group claims, with
//! the text we print for it, hashed in sweep order. The fixture in
//! tests/fixtures/disasm/digests.zig holds the value each sweep must reach; it
//! was captured while every swept encoding printed exactly as the reference
//! disassembler printed it (RA8EMU-708).
const std = @import("std");
const ra8 = @import("ra8");
const Instr = ra8.chip.core.cpu.instr.Instr;
const disasm = ra8.chip.core.cpu.decode.text.disasm;
const digests = @import("../../../../fixtures/disasm/digests.zig");

pub const Sweep = struct {
    hash: std.crypto.hash.sha2.Sha256 = .init(.{}),
    count: u32 = 0,

    pub fn add(self: *Sweep, instr: Instr) void {
        var head: [16]u8 = undefined;
        const line = std.fmt.bufPrint(&head, "{x:0>4} {x:0>4} ", .{ instr.hw1, instr.hw2 }) catch unreachable;
        self.hash.update(line);
        if (disasm.one(instr)) |text| self.hash.update(text.slice()) else self.hash.update("?");
        self.hash.update("\n");
        self.count += 1;
    }
};

/// Names one sweep: its form, group and every parameter that picks its
/// encodings, so two sweeps of the same group get different fixtures.
pub fn callKey(wide: bool, group: []const u8, mask: u16, value: u16, list: []const u16) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(&.{@intFromBool(wide)});
    h.update(group);
    h.update(std.mem.asBytes(&mask));
    h.update(std.mem.asBytes(&value));
    h.update(std.mem.sliceAsBytes(list));
    return h.final();
}

/// Fails unless the sweep matches its fixture. On a miss it prints the fixture
/// line the sweep now produces, which is the line to commit when a printer
/// changed on purpose.
pub fn expectFixture(group: []const u8, call: u64, sweep: *Sweep) !void {
    try std.testing.expect(sweep.count > 0);
    var out: [32]u8 = undefined;
    sweep.hash.final(&out);
    const hex = std.fmt.bytesToHex(out, .lower);
    if (digests.find(group, call)) |want| {
        if (want.count == sweep.count and std.mem.eql(u8, want.sha256, &hex)) return;
    }
    std.debug.print("disasm digest for {s} differs; fixture line now:\n    .{{ .group = \"{s}\", .call = 0x{x:0>16}, .count = {d}, .sha256 = \"{s}\" }},\n", .{ group, group, call, sweep.count, hex });
    return error.TestUnexpectedResult;
}
