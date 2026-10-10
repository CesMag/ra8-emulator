//! Tests for src/chip/periph/lococr.zig.
const std = @import("std");
const ra8 = @import("ra8");
const loco = ra8.chip.periph.subclock.loco;
const prcr = ra8.chip.periph.prcr;

const Fixture = struct {
    protection: prcr.Prcr,
    unit: loco.Unit,

    fn init(self: *Fixture) void {
        self.protection = prcr.Prcr.init();
        self.unit = loco.Unit.init(&self.protection);
    }

    fn unlock(self: *Fixture) void {
        self.protection.write(prcr.win_base, 2, prcr.unlockWord(loco.guard));
    }

    fn lock(self: *Fixture) void {
        self.protection.write(prcr.win_base, 2, prcr.unlockWord(0));
    }
};

test "the LOCO comes up running and the block is quiet" {
    var fix: Fixture = undefined;
    fix.init();
    try std.testing.expect(fix.unit.running());
    try std.testing.expect(fix.unit.quiet());
    try std.testing.expectEqual(@as(u32, 0), fix.unit.read(loco.address, 1));
}

test "a locked store is dropped and counted" {
    var fix: Fixture = undefined;
    fix.init();
    fix.lock();
    fix.unit.write(loco.address, 1, loco.lcstp);
    try std.testing.expect(fix.unit.running());
    try std.testing.expectEqual(@as(u32, 1), fix.unit.dropped_locked);
    try std.testing.expect(!fix.unit.quiet());
}

test "setting LCSTP stops the LOCO and clearing it starts it again" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.unit.write(loco.address, 1, loco.lcstp);
    try std.testing.expect(!fix.unit.running());
    try std.testing.expectEqual(@as(u32, 1), fix.unit.read(loco.address, 1));
    fix.unit.write(loco.address, 1, 0);
    try std.testing.expect(fix.unit.running());
    try std.testing.expectEqual(@as(u32, 1), fix.unit.stops);
    try std.testing.expectEqual(@as(u32, 1), fix.unit.starts);
    try std.testing.expectEqual(@as(u32, 2), fix.unit.stores);
}

test "the driver's read-modify-write of bit 0 round-trips" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    const now: u8 = @truncate(fix.unit.read(loco.address, 1));
    fix.unit.write(loco.address, 1, now | loco.lcstp);
    const back: u8 = @truncate(fix.unit.read(loco.address, 1));
    fix.unit.write(loco.address, 1, back & ~loco.lcstp);
    try std.testing.expectEqual(@as(u8, 0), fix.unit.lococr);
}

test "the block puts LOCOCR on the bus" {
    var bus = ra8.chip.periph.registry.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    try bus.add(fix.unit.block());
    bus.write(0x4001_E400, 1, 1);
    try std.testing.expect(!fix.unit.running());
}
