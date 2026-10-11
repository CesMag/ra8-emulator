//! Tests for src/chip/periph/scb/bank.zig.

const std = @import("std");
const ra8 = @import("ra8");
const bank = ra8.chip.periph.scb.bank;
const alias = ra8.chip.periph.scs_alias;

fn word(address: u32, secure: bool) u32 {
    const target = alias.route(address, secure).register;
    return bank.backing(target).word;
}

test "the table matches the D1.2 attribute lines" {
    try std.testing.expectEqual(bank.Banking.banked, bank.banking(0xE000_ED08).?); // VTOR
    try std.testing.expectEqual(bank.Banking.banked, bank.banking(0xE000_ED88).?); // CPACR
    try std.testing.expectEqual(bank.Banking.bit_by_bit, bank.banking(0xE000_ED0C).?); // AIRCR
    try std.testing.expectEqual(bank.Banking.bit_by_bit, bank.banking(0xE000_ED28).?); // CFSR
    try std.testing.expectEqual(bank.Banking.not_banked, bank.banking(0xE000_ED2C).?); // HFSR
    try std.testing.expectEqual(bank.Banking.not_banked, bank.banking(0xE000_ED00).?); // CPUID
}

test "addresses the table has not read up on are null" {
    try std.testing.expect(bank.banking(0xE000_ED3C) == null);
    try std.testing.expect(bank.banking(0xE000_ED90) == null);
    try std.testing.expect(bank.banking(0xE000_E100) == null);
}

test "VTOR: Secure and Non-secure copies live apart" {
    try std.testing.expectEqual(@as(u32, 0xE000_ED08), word(0xE000_ED08, true));
    try std.testing.expectEqual(@as(u32, 0xE002_ED08), word(0xE000_ED08, false));
}

test "Secure code on VTOR_NS and Non-secure code on VTOR share one word" {
    try std.testing.expectEqual(word(0xE000_ED08, false), word(0xE002_ED08, true));
    try std.testing.expectEqual(ra8.chip.core.memmap.scb.vtor_ns, word(0xE002_ED08, true));
}

test "an unbanked register has one home from every view" {
    try std.testing.expectEqual(@as(u32, 0xE000_ED2C), word(0xE000_ED2C, true));
    try std.testing.expectEqual(@as(u32, 0xE000_ED2C), word(0xE000_ED2C, false));
    try std.testing.expectEqual(@as(u32, 0xE000_ED2C), word(0xE002_ED2C, true));
}

test "a bit-by-bit register is handed back, not placed" {
    const target = alias.route(0xE000_ED24, false).register;
    const answer = bank.backing(target);
    try std.testing.expectEqual(@as(u32, 0xE000_ED24), answer.bit_by_bit.address);
    try std.testing.expectEqual(alias.View.non_secure, answer.bit_by_bit.view);
}

test "bankedBits: whole, none, and AIRCR's PRIGROUP" {
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), bank.bankedBits(0xE000_ED08, .one).?);
    try std.testing.expectEqual(@as(u32, 0), bank.bankedBits(0xE000_ED2C, .one).?);
    try std.testing.expectEqual(@as(u32, 0x0000_0700), bank.bankedBits(0xE000_ED0C, .one).?);
    try std.testing.expect(bank.bankedBits(0xE000_ED3C, .one) == null);
}

test "bankedBits: SCR keeps SLEEPDEEP and SLEEPDEEPS shared" {
    const scr = bank.bankedBits(0xE000_ED10, .one).?;
    try std.testing.expectEqual(@as(u32, (1 << 4) | (1 << 1)), scr);
    try std.testing.expect(scr & (1 << 2) == 0);
    try std.testing.expect(scr & (1 << 3) == 0);
}

test "bankedBits: CCR banks everything named but BFHFNMIGN" {
    const ccr = bank.bankedBits(0xE000_ED14, .one).?;
    const named: u32 = (1 << 18) | (1 << 17) | (1 << 16) | (1 << 10) | (1 << 4) | (1 << 3) | (1 << 1);
    try std.testing.expectEqual(named, ccr);
    try std.testing.expect(ccr & (1 << 8) == 0);
}

test "bankedBits: ICSR, SHPR1 and CFSR fields" {
    try std.testing.expectEqual(@as(u32, (1 << 28) | (1 << 27)), bank.bankedBits(0xE000_ED04, .one).?);
    try std.testing.expectEqual(@as(u32, 0x00FF_00FF), bank.bankedBits(0xE000_ED18, .one).?);
    try std.testing.expectEqual(@as(u32, 0xFFFF_00FF), bank.bankedBits(0xE000_ED28, .one).?);
}

test "bankedBits: the SysTick fields bank only with two SysTicks" {
    try std.testing.expectEqual(@as(u32, 0x00FF_0000), bank.bankedBits(0xE000_ED20, .one).?);
    try std.testing.expectEqual(@as(u32, 0xFFFF_0000), bank.bankedBits(0xE000_ED20, .two).?);
    const shcsr = bank.bankedBits(0xE000_ED24, .one).?;
    try std.testing.expect(shcsr & (1 << 11) == 0);
    try std.testing.expect(bank.bankedBits(0xE000_ED24, .two).? & (1 << 11) != 0);
}

test "bankedBits: SHCSR keeps BusFault, SecureFault and NMI shared" {
    const shcsr = bank.bankedBits(0xE000_ED24, .two).?;
    const shared: u32 = (1 << 20) | (1 << 19) | (1 << 17) | (1 << 14) | (1 << 8) | (1 << 5) | (1 << 4) | (1 << 1);
    try std.testing.expectEqual(@as(u32, 0), shcsr & shared);
    try std.testing.expectEqual(@as(u32, 0x0025_BC8D), shcsr);
}

test "bankedBits: ICSR banks PENDST only with two SysTick timers" {
    try std.testing.expectEqual(@as(u32, 0x1E00_0000), bank.bankedBits(0xE000_ED04, .two).?);
}

test "every bit-by-bit register now has a split" {
    for ([_]u32{ 0x04, 0x0C, 0x10, 0x14, 0x18, 0x20, 0x24, 0x28 }) |offset| {
        try std.testing.expect(bank.bankedBits(0xE000_ED00 + offset, .one) != null);
    }
}

test "SysTicks.of maps a timer count" {
    try std.testing.expectEqual(bank.SysTicks.one, bank.SysTicks.of(1));
    try std.testing.expectEqual(bank.SysTicks.two, bank.SysTicks.of(2));
}
