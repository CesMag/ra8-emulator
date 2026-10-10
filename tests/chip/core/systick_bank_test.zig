//! Tests for src/chip/core/systick_bank.zig: the Secure and Non-secure SysTick of
//! one core.
const std = @import("std");
const ra8 = @import("ra8");
const bank = ra8.chip.core.systick_bank;
const clocks = ra8.chip.periph.clocks;

const run = clocks.csr_enable | clocks.csr_tickint;

test "the two timers of a bank count at their own reloads" {
    var b = bank.Bank{};
    b.secure = .{ .csr = run, .rvr = 9, .cvr = 9 };
    b.non_secure = .{ .csr = run, .rvr = 99, .cvr = 99 };
    b.advance(25);
    try std.testing.expectEqual(@as(u32, 4), b.secure.cvr);
    try std.testing.expectEqual(@as(u32, 74), b.non_secure.cvr);
    try std.testing.expect(b.secure.pending);
    try std.testing.expect(!b.non_secure.pending);
}

test "only the timer that wrapped pends and sets COUNTFLAG" {
    var b = bank.Bank{};
    b.secure = .{ .csr = clocks.csr_enable, .rvr = 3, .cvr = 3 };
    b.non_secure = .{ .csr = run, .rvr = 3, .cvr = 3 };
    b.advance(4);
    try std.testing.expect(!b.secure.pending);
    try std.testing.expect(b.non_secure.pending);
    try std.testing.expect(b.secure.readCsr() & clocks.csr_countflag != 0);
    try std.testing.expect(b.secure.readCsr() & clocks.csr_countflag == 0);
}

test "a disabled timer does not move while its pair runs" {
    var b = bank.Bank{};
    b.secure = .{ .rvr = 9, .cvr = 9 };
    b.non_secure = .{ .csr = run, .rvr = 9, .cvr = 9 };
    b.advance(5);
    try std.testing.expectEqual(@as(u32, 9), b.secure.cvr);
    try std.testing.expectEqual(@as(u32, 4), b.non_secure.cvr);
    try std.testing.expectEqual(@as(u64, 0), b.secure.advance(100));
}

test "the normal window answers in the requester's own state" {
    try std.testing.expectEqual(bank.Route{ .view = .secure, .register = .csr }, bank.route(0xE000_E010, .secure).?);
    try std.testing.expectEqual(bank.Route{ .view = .non_secure, .register = .cvr }, bank.route(0xE000_E018, .non_secure).?);
    try std.testing.expectEqual(bank.Route{ .view = .secure, .register = .calib }, bank.route(0xE000_E01C, .secure).?);
}

test "the alias is Secure code's view of the Non-secure timer" {
    try std.testing.expectEqual(bank.Route{ .view = .non_secure, .register = .rvr }, bank.route(0xE002_E014, .secure).?);
    try std.testing.expectEqual(@as(?bank.Route, null), bank.route(0xE002_E014, .non_secure));
}

test "addresses outside both windows reach no timer" {
    try std.testing.expectEqual(@as(?bank.Route, null), bank.route(0xE000_E020, .secure));
    try std.testing.expectEqual(@as(?bank.Route, null), bank.route(0xE002_E00C, .secure));
}

test "a bank hands out the timer for each view" {
    var b = bank.Bank{};
    b.of(.non_secure).rvr = 7;
    try std.testing.expectEqual(@as(u32, 7), b.non_secure.rvr);
    try std.testing.expectEqual(@as(u32, 0), b.of(.secure).rvr);
}

const pendsv_set: u32 = 1 << 28;
const pendst_set: u32 = 1 << 26;
const idle = bank.Words{ .icsr = 0, .shpr3 = 0 };

test "pends: nothing pending gives no pends" {
    try std.testing.expectEqual(@as(usize, 0), bank.pends(idle, idle, true).slice().len);
}

test "pends: each state's PendSV and SysTick carry that state's priority" {
    const secure = bank.Words{ .icsr = pendsv_set, .shpr3 = 0x4020_0000 };
    const ns = bank.Words{ .icsr = pendst_set, .shpr3 = 0xC0E0_0000 };
    const got = bank.pends(secure, ns, true);
    try std.testing.expectEqualSlices(bank.Pend, &.{
        .{ .number = bank.pendsv, .priority = 0x20, .view = .secure },
        .{ .number = bank.systick, .priority = 0xC0, .view = .non_secure },
    }, got.slice());
}

test "pends: both states pending at once give four pends" {
    const both = pendsv_set | pendst_set;
    const got = bank.pends(.{ .icsr = both, .shpr3 = 0x1011_0000 }, .{ .icsr = both, .shpr3 = 0x2022_0000 }, true);
    try std.testing.expectEqual(@as(usize, 4), got.slice().len);
    try std.testing.expectEqual(bank.Pend{ .number = bank.pendsv, .priority = 0x22, .view = .non_secure }, got.slice()[2]);
    try std.testing.expectEqual(bank.Pend{ .number = bank.systick, .priority = 0x20, .view = .non_secure }, got.slice()[3]);
}

test "pends: with one timer SysTick is only ever Secure" {
    const ns = bank.Words{ .icsr = pendsv_set | pendst_set, .shpr3 = 0x8080_0000 };
    const got = bank.pends(.{ .icsr = pendst_set, .shpr3 = 0x4000_0000 }, ns, false);
    try std.testing.expectEqualSlices(bank.Pend, &.{
        .{ .number = bank.systick, .priority = 0x40, .view = .secure },
        .{ .number = bank.pendsv, .priority = 0x80, .view = .non_secure },
    }, got.slice());
}

test "two armed timers ask for the shorter period, one for its own" {
    try std.testing.expectEqual(@as(u32, 0), bank.width(0, 0));
    try std.testing.expectEqual(@as(u32, 40), bank.width(40, 0));
    try std.testing.expectEqual(@as(u32, 25), bank.width(0, 25));
    try std.testing.expectEqual(@as(u32, 25), bank.width(40, 25));
}

test "the Non-secure time base counts at the alias and pends only its own ICSR" {
    const words = bank.non_secure_words;
    try std.testing.expectEqual(@as(u32, 0xE002_E010), words.csr);
    try std.testing.expectEqual(@as(u32, 0xE002_ED04), words.icsr);
    var store = try ra8.chip.core.cpu.memory.store.Store.init(null);
    defer store.deinit();
    const core: ra8.chip.core.cpu.memory.guest.Guest = .{ .store = &store };
    try core.writeWord(words.rvr, 9);
    try core.writeWord(words.cvr, 3);
    try core.writeWord(words.csr, run);
    try core.writeWord(0xE000_EDFC, 1 << 24); // DEMCR.TRCENA
    try core.writeWord(0xE000_1000, 1); // DWT_CTRL.CYCCNTENA
    var clock = clocks.Clocks{ .words = words };
    try std.testing.expectEqual(@as(u32, 10), clock.period(core));
    try clock.advanceSysTick(core, 5);
    try std.testing.expectEqual(@as(u32, 8), try core.readWord(words.cvr));
    try std.testing.expect(try core.readWord(words.csr) & clocks.csr_countflag != 0);
    try std.testing.expectEqual(clocks.icsr_pendstset, try core.readWord(0xE002_ED04));
    try std.testing.expectEqual(@as(u32, 0), try core.readWord(0xE000_ED04));
    try std.testing.expectEqual(@as(u32, 0), try core.readWord(0xE000_E018));
    try std.testing.expectEqual(@as(u32, 0), try core.readWord(0xE000_1004));
}
