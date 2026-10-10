const std = @import("std");
const ra8 = @import("ra8");
const pscu = ra8.chip.periph.pscu;
const mstp = ra8.chip.periph.mstp;

const psarb = pscu.win_base + 0x04;
const psare = pscu.win_base + 0x10;

test "every attribution word resets to Secure-owned" {
    var unit = pscu.Unit{};
    try std.testing.expectEqual(@as(u32, 0), unit.read(psarb, 4));
    try std.testing.expectEqual(@as(u32, 0), unit.read(psare, 4));
    try std.testing.expect(!unit.anyDelegated());
    try std.testing.expect(unit.quiet());
}

test "the reserved word at the base is not a register" {
    var unit = pscu.Unit{};
    unit.write(pscu.win_base, 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), unit.read(pscu.win_base, 4));
    try std.testing.expectEqual(@as(u32, 1), unit.reserved_stores);
    try std.testing.expectEqual(@as(u32, 0), unit.stores);
    try std.testing.expect(!unit.anyDelegated());
}

test "MSTPCRA has no attribution register, so nothing in it is delegated" {
    var unit = pscu.Unit{};
    unit.write(psarb, 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), unit.nonsecureMask(0));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), unit.nonsecureMask(1));
}

test "a store lands on the word it names and nowhere else" {
    var unit = pscu.Unit{};
    unit.write(psare, 4, 1 << 31);
    try std.testing.expectEqual(@as(u32, 1 << 31), unit.nonsecureMask(4));
    try std.testing.expectEqual(@as(u32, 0), unit.nonsecureMask(2));
    try std.testing.expectEqual(@as(u32, 1), unit.stores);
    try std.testing.expect(unit.anyDelegated());
    try std.testing.expect(!unit.quiet());
}

test "a Secure store cannot move a delegated module-stop bit" {
    var words = pscu.Unit{};
    words.write(psarb, 4, 1 << 11);
    var modules = mstp.Mstp{ .attribution = &words };
    const mstpcrb = mstp.win_base + 4;
    modules.applyWrite(mstpcrb, 4, 0);
    // Bit 11 was delegated, so it keeps the value the Secure write refused
    // to clear; every other bit in the register cleared.
    try std.testing.expectEqual(@as(u32, 1 << 11), modules.readReg(mstpcrb, 4));
    try std.testing.expect(modules.masked_writes != 0);
}

test "with nothing delegated a Secure store moves the whole register" {
    var words = pscu.Unit{};
    var modules = mstp.Mstp{ .attribution = &words };
    const mstpcrb = mstp.win_base + 4;
    modules.applyWrite(mstpcrb, 4, 0);
    try std.testing.expectEqual(@as(u32, 0), modules.readReg(mstpcrb, 4));
    try std.testing.expectEqual(@as(u32, 0), modules.masked_writes);
}

test "a board with no attribution block delegates nothing" {
    var modules = mstp.Mstp{};
    const mstpcre = mstp.win_base + 0x10;
    modules.applyWrite(mstpcre, 4, 0);
    try std.testing.expectEqual(@as(u32, 0), modules.readReg(mstpcre, 4));
    try std.testing.expectEqual(@as(u32, 0), modules.masked_writes);
}

const samon = pscu.samon;

test "an unprogrammed CMSAMON and SFSAMON read the blank part's area" {
    const unit = samon.Unit{};
    try std.testing.expectEqual(@as(u32, 0x1FF) << 15, unit.read(samon.cms_address, 4));
    try std.testing.expectEqual(@as(u32, 0x1FF) << 15, unit.read(samon.sfs_address, 4));
}

test "each monitor reads its own programmed area in bits 23:15" {
    const unit = samon.Unit{ .cms = 2, .sfs = 5 };
    try std.testing.expectEqual(@as(u32, 2) << 15, unit.read(samon.cms_address, 4));
    try std.testing.expectEqual(@as(u32, 5) << 15, unit.read(samon.sfs_address, 4));
}

test "the monitors drop stores and count them" {
    var unit = samon.Unit{ .cms = 2 };
    unit.write(samon.cms_address, 4, 0);
    unit.write(samon.sfs_address, 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 2) << 15, unit.read(samon.cms_address, 4));
    try std.testing.expectEqual(@as(u32, 2), unit.ignored_stores);
}

test "the CMS area a monitor reads is the one the IDAU narrows code by" {
    const unit = samon.Unit{ .cms = 2 };
    const area: u9 = @intCast(unit.read(samon.cms_address, 4) >> samon.area_shift);
    const map = ra8.chip.periph.sau.idau.Map{ .code_secure = ra8.chip.periph.sau.idau.cmsBytes(area) };
    const State = ra8.chip.periph.sau.attribution.State;
    try std.testing.expectEqual(State.secure, map.answer(0x1200_FFFF).state);
    try std.testing.expectEqual(State.non_secure, map.answer(0x1201_0000).state);
}

test "the two monitor windows sit at PSCU +0x30 and +0x3C, four bytes each" {
    var unit = samon.Unit{};
    const windows = unit.blocks();
    try std.testing.expectEqual(@as(u32, 0x4020_4030), windows[0].base);
    try std.testing.expectEqual(@as(u32, 0x4020_403C), windows[1].base);
    try std.testing.expectEqual(@as(u32, 4), windows[0].size);
    try std.testing.expect(windows[0].base >= pscu.win_base + pscu.win_span);
}
