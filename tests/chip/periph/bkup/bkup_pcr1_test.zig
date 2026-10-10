//! Tests for src/chip/periph/bkup/bkup_pcr1.zig.
const std = @import("std");
const ra8 = @import("ra8");
const pcr1 = ra8.chip.periph.bkup.pcr1;
const prcr = ra8.chip.periph.prcr;

const Fixture = struct {
    protection: prcr.Prcr,
    unit: pcr1.Pcr1,

    fn init(self: *Fixture) void {
        self.protection = prcr.Prcr.init();
        self.unit = pcr1.Pcr1.init(&self.protection);
    }

    fn unlock(self: *Fixture) void {
        self.protection.write(prcr.win_base, 2, prcr.unlockWord(pcr1.guard));
    }
};

test "the switch comes up enabled and the block is quiet" {
    var fix: Fixture = undefined;
    fix.init();
    try std.testing.expect(fix.unit.switchEnabled());
    try std.testing.expect(fix.unit.quiet());
    try std.testing.expectEqual(@as(u32, 0), fix.unit.read(pcr1.address, 1));
}

test "a store with PRC1 locked is dropped and counted" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unit.write(pcr1.address, 1, pcr1.bpwswstp);
    try std.testing.expect(fix.unit.switchEnabled());
    try std.testing.expectEqual(@as(u32, 1), fix.unit.dropped_locked);
}

test "PRC0 alone does not open the register" {
    var fix: Fixture = undefined;
    fix.init();
    fix.protection.write(prcr.win_base, 2, prcr.unlockWord(prcr.group.cgc));
    fix.unit.write(pcr1.address, 1, pcr1.bpwswstp);
    try std.testing.expect(fix.unit.switchEnabled());
}

test "BPWSWSTP stops the switch and clearing it enables it again" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.unit.write(pcr1.address, 1, pcr1.bpwswstp);
    try std.testing.expect(!fix.unit.switchEnabled());
    try std.testing.expectEqual(@as(u32, 1), fix.unit.read(pcr1.address, 1));
    fix.unit.write(pcr1.address, 1, 0);
    try std.testing.expect(fix.unit.switchEnabled());
    try std.testing.expectEqual(@as(u32, 1), fix.unit.stops);
    try std.testing.expectEqual(@as(u32, 1), fix.unit.enables);
}

test "the block puts VBTBPCR1 on the bus" {
    var bus = ra8.chip.periph.registry.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    try bus.add(fix.unit.block());
    bus.write(0x4001_EA88, 1, 1);
    try std.testing.expect(!fix.unit.switchEnabled());
}
