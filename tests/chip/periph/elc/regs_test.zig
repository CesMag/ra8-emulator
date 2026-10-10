//! Covers src/chip/periph/elc/regs.zig: the ELC register map, and which lanes of a
//! word each register occupies.
const std = @import("std");
const ra8 = @import("ra8");

const regs = ra8.chip.periph.elc.regs;

test "each register decodes from the word it sits in" {
    try std.testing.expectEqual(regs.Reg.control, regs.decode(regs.off.elcr).?);
    try std.testing.expectEqual(@as(usize, 0), regs.decode(regs.off.elsegr).?.generator);
    try std.testing.expectEqual(@as(usize, 3), regs.decode(regs.off.elsegr + 0x0C).?.generator);
    try std.testing.expectEqual(@as(usize, 0), regs.decode(regs.off.elsr).?.link);
    try std.testing.expectEqual(@as(usize, 7), regs.decode(regs.off.elsr + 7 * 4).?.link);
}

test "the two attribution groups are one run of six" {
    try std.testing.expectEqual(@as(usize, 0), regs.decode(regs.off.elcsara).?.attribution);
    try std.testing.expectEqual(@as(usize, 2), regs.decode(regs.off.elcsara + 8).?.attribution);
    try std.testing.expectEqual(@as(usize, 3), regs.decode(regs.off.elcpara).?.attribution);
    try std.testing.expectEqual(@as(usize, 5), regs.decode(regs.off.elcpara + 8).?.attribution);
}

test "a word past the last of a run is reserved, not the run's neighbour" {
    // The gap between the four generators and ELSR0, the gap after the last
    // slot, and the gap between the two attribution groups.
    try std.testing.expectEqual(@as(?regs.Reg, null), regs.decode(0x014));
    try std.testing.expectEqual(@as(?regs.Reg, null), regs.decode(regs.off.elsr + regs.links * 4));
    try std.testing.expectEqual(@as(?regs.Reg, null), regs.decode(regs.off.elcsara + 12));
}

test "a register occupies only the lanes it is wide" {
    try std.testing.expectEqual(@as(u32, 0xFF), regs.occupied(.control));
    try std.testing.expectEqual(@as(u32, 0xFF), regs.occupied(.{ .generator = 0 }));
    try std.testing.expectEqual(@as(u32, 0xFFFF), regs.occupied(.{ .link = 0 }));
    try std.testing.expectEqual(~@as(u32, 0), regs.occupied(.{ .attribution = 0 }));
}

test "an access reaches a register only when it names an occupied lane" {
    // ELSEGRn is one byte: the three above it are reserved space.
    try std.testing.expect(regs.reaches(.{ .generator = 0 }, 0, 1));
    try std.testing.expect(!regs.reaches(.{ .generator = 0 }, 1, 1));
    try std.testing.expect(!regs.reaches(.{ .generator = 0 }, 2, 2));
    // A word access covers the byte whatever else it covers.
    try std.testing.expect(regs.reaches(.{ .generator = 0 }, 0, 4));
}

test "both bytes of ELSR are the register, the half above it is not" {
    try std.testing.expect(regs.reaches(.{ .link = 0 }, 0, 1));
    try std.testing.expect(regs.reaches(.{ .link = 0 }, 1, 1));
    try std.testing.expect(!regs.reaches(.{ .link = 0 }, 2, 1));
    try std.testing.expect(!regs.reaches(.{ .link = 0 }, 2, 2));
}

test "the window covers every register it decodes" {
    try std.testing.expect(regs.off.elcpara + regs.attribution_group * 4 <= regs.win_span);
    try std.testing.expectEqual(@as(usize, 6), regs.attributions);
    try std.testing.expectEqual(@as(usize, 4), regs.generators);
}
