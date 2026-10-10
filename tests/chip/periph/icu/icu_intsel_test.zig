//! Covers src/chip/periph/icu/icu_intsel.zig: the INTSELR bank's addresses, its
//! fixed-zero bits, narrow stores, and the per-event core answer.
const std = @import("std");
const ra8 = @import("ra8");

const intsel = ra8.chip.periph.icu.intsel;

test "the bank sits where the COMMON_ICU map puts it" {
    try std.testing.expectEqual(@as(u32, 0x4000_6040), intsel.wordAddress(0));
    try std.testing.expectEqual(@as(u32, 0x4000_60BC), intsel.wordAddress(31));
    try std.testing.expectEqual(@as(usize, 1024), intsel.events);
}

test "every event is a CPU0 factor out of reset" {
    const bank = intsel.Intsel{};
    try std.testing.expectEqual(intsel.Core.cpu0, bank.coreFor(1));
    try std.testing.expectEqual(intsel.Core.cpu0, bank.coreFor(1023));
}

test "a set IS bit hands that event to CPU1 and no other" {
    var bank = intsel.Intsel{};
    bank.write(intsel.wordAddress(0), 4, 1 << 2);
    try std.testing.expectEqual(intsel.Core.cpu1, bank.coreFor(2));
    try std.testing.expectEqual(intsel.Core.cpu0, bank.coreFor(1));
    try std.testing.expectEqual(intsel.Core.cpu0, bank.coreFor(3));
}

test "only assigned and non-fixed event bits accept stores" {
    const expected = [_]u32{
        0xFFFFFFFE, 0x00000001, 0x84C0FFFF, 0x00E33B1F,
        0xFFFC0FFF, 0xFE5FFBDF, 0x07FFF3FF, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0xFFFFFFFF, 0x7FBFDFFF, 0xFBFDFEFF, 0x7FFFFFFF,
        0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0xFC000000, 0x03FFFFFB, 0xFFFFFFFE, 0xFFFFFFFF,
        0xFFFFFFFF, 0xFF3FF33F, 0xFFFFFFFF, 0x0002DFDF,
        0x00FFBF3C, 0x00000000, 0x00000000, 0x00000000,
    };
    var bank = intsel.Intsel{};
    for (0..intsel.words) |index| {
        bank.write(intsel.wordAddress(index), 4, 0xFFFF_FFFF);
        try std.testing.expectEqual(expected[index], bank.read(intsel.wordAddress(index), 4));
    }
    for (intsel.fixed) |event| try std.testing.expectEqual(intsel.Core.cpu0, bank.coreFor(event));
    for (0..intsel.events) |event| {
        const assigned = (expected[event / 32] & (@as(u32, 1) << @intCast(event % 32))) != 0;
        try std.testing.expectEqual(if (assigned) intsel.Core.cpu1 else intsel.Core.cpu0, bank.coreFor(@intCast(event)));
    }
}

test "a byte store keeps lanes containing assigned events" {
    var bank = intsel.Intsel{};
    bank.write(intsel.wordAddress(1), 4, 0x0000_00FF);
    bank.write(intsel.wordAddress(2) + 2, 1, 0x80);
    try std.testing.expectEqual(@as(u32, 0x0000_0001), bank.read(intsel.wordAddress(1), 4));
    try std.testing.expectEqual(@as(u32, 0x0080_0000), bank.read(intsel.wordAddress(2), 4));
    try std.testing.expectEqual(@as(u32, 0x80), bank.read(intsel.wordAddress(2) + 2, 1));
    try std.testing.expectEqual(intsel.Core.cpu1, bank.coreFor(87));
}

test "an address outside the bank reads zero and keeps nothing" {
    var bank = intsel.Intsel{};
    bank.write(intsel.base + intsel.win_span, 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), bank.read(intsel.base + intsel.win_span, 4));
    try std.testing.expectEqual(@as(u32, 0), bank.read(intsel.base - 4, 4));
}

test "the block names the bank's window" {
    var bank = intsel.Intsel{};
    const window = bank.block();
    try std.testing.expectEqual(intsel.base, window.base);
    try std.testing.expectEqual(intsel.win_span, window.size);
}
