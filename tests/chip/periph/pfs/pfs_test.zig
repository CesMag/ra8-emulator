const std = @import("std");
const ra8 = @import("ra8");
const pfs = ra8.chip.periph.pfs;
const protect = ra8.chip.periph.pfs.protect;

const pwpr = pfs.win_base + pfs.region.pmisc + protect.off.pwpr;
const pwprs = pfs.win_base + pfs.region.pmisc + protect.off.pwprs;

fn unlock(unit: *pfs.Pfs) void {
    unit.write(pwpr, 1, 0);
    unit.write(pwpr, 1, protect.field.pfswe);
    unit.write(pwprs, 1, 0);
    unit.write(pwprs, 1, protect.field.pfswe);
}

fn lock(unit: *pfs.Pfs) void {
    unit.write(pwpr, 1, 0);
    unit.write(pwpr, 1, protect.field.b0wi);
    unit.write(pwprs, 1, 0);
    unit.write(pwprs, 1, protect.field.b0wi);
}

test "a pin write without the unlock goes nowhere and is counted" {
    var unit = pfs.Pfs.init();
    unit.write(pfs.Pfs.pinAddress(6, 0), 4, 0x0001_0004);
    try std.testing.expectEqual(@as(u32, 0), unit.pin(6, 0));
    try std.testing.expectEqual(@as(u32, 1), unit.guard.refused);
    try std.testing.expectEqual(@as(u32, 0), unit.programmed);
}

test "the driver's own sequence lets a pin write land" {
    var unit = pfs.Pfs.init();
    unlock(&unit);
    unit.write(pfs.Pfs.pinAddress(6, 0), 4, 0x0001_0004);
    try std.testing.expectEqual(@as(u32, 0x0001_0004), unit.pin(6, 0));
    try std.testing.expectEqual(@as(u32, 1), unit.programmed);
    try std.testing.expectEqual(@as(u32, 0), unit.guard.refused);
}

test "re-locking closes the window behind the burst" {
    var unit = pfs.Pfs.init();
    unlock(&unit);
    unit.write(pfs.Pfs.pinAddress(3, 3), 4, 0x0000_0004);
    lock(&unit);
    unit.write(pfs.Pfs.pinAddress(3, 3), 4, 0x0000_0010);
    try std.testing.expectEqual(@as(u32, 0x0000_0004), unit.pin(3, 3));
    try std.testing.expectEqual(@as(u32, 1), unit.guard.refused);
}

test "unlocking only the non-secure path is not enough" {
    var unit = pfs.Pfs.init();
    unit.write(pwpr, 1, 0);
    unit.write(pwpr, 1, protect.field.pfswe);
    unit.write(pfs.Pfs.pinAddress(10, 7), 4, 0x1000_0000);
    try std.testing.expectEqual(@as(u32, 0), unit.pin(10, 7));
    try std.testing.expectEqual(@as(u32, 1), unit.guard.refused);
}

test "a pin reads back what was programmed, cut to the access" {
    var unit = pfs.Pfs.init();
    unlock(&unit);
    const at = pfs.Pfs.pinAddress(0, 1);
    unit.write(at, 4, 0x0301_0004);
    try std.testing.expectEqual(@as(u32, 0x0301_0004), unit.read(at, 4));
    try std.testing.expectEqual(@as(u32, 0x04), unit.read(at, 1));
    try std.testing.expectEqual(@as(u32, 0x0301), unit.read(at + 2, 2));
}

test "a narrow store leaves the lanes it does not name alone" {
    var unit = pfs.Pfs.init();
    unlock(&unit);
    const at = pfs.Pfs.pinAddress(2, 5);
    unit.write(at, 4, 0xAABB_CCDD);
    unit.write(at + 1, 1, 0x11);
    try std.testing.expectEqual(@as(u32, 0xAABB_11DD), unit.pin(2, 5));
}

test "pins are addressed flat, port times sixteen plus pin" {
    try std.testing.expectEqual(@as(u32, 0), pfs.Pfs.indexOf(0, 0));
    try std.testing.expectEqual(@as(u32, 16), pfs.Pfs.indexOf(1, 0));
    try std.testing.expectEqual(@as(u32, 0x4040_0800 + 4), pfs.Pfs.pinAddress(0, 1));
    try std.testing.expectEqual(@as(u32, 0x4040_0800 + 0x100), pfs.Pfs.pinAddress(4, 0));
}

test "the last pin of the last port is still inside the array" {
    var unit = pfs.Pfs.init();
    unlock(&unit);
    const at = pfs.Pfs.pinAddress(14, 15);
    try std.testing.expect(at - pfs.win_base < pfs.region.pfs_end);
    unit.write(at, 4, 0x0000_0002);
    try std.testing.expectEqual(@as(u32, 0x0000_0002), unit.pin(14, 15));
}

test "the rest of PMISC is a shadow that reads back" {
    var unit = pfs.Pfs.init();
    const pmsar = pfs.win_base + pfs.region.pmisc + 0x030;
    unit.write(pmsar, 4, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), unit.read(pmsar, 4));
    try std.testing.expectEqual(@as(u32, 0), unit.guard.refused);
}

test "the write protect registers read back their own state" {
    var unit = pfs.Pfs.init();
    try std.testing.expectEqual(@as(u32, protect.field.b0wi), unit.read(pwprs, 1));
    unlock(&unit);
    try std.testing.expectEqual(@as(u32, protect.field.pfswe), unit.read(pwprs, 1));
}

test "a run that never touched a pin says nothing" {
    var unit = pfs.Pfs.init();
    try std.testing.expect(unit.quiet());
    unlock(&unit);
    try std.testing.expect(unit.quiet());
}
