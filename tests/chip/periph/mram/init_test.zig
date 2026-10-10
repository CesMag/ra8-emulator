const std = @import("std");
const ra8 = @import("ra8");
const mram = ra8.chip.periph.mram;
const init_reg = ra8.chip.periph.mram.init;

const full_init: u32 = 0xAA01;
const msuinitr = mram.regs.base + init_reg.off;

fn block() mram.Mram {
    return mram.Mram.init(std.testing.allocator);
}

test "a keyed kick runs the init and leaves SUINIT clear on the first poll" {
    var unit = block();
    defer unit.deinit();
    unit.write(msuinitr, 2, full_init);
    try std.testing.expectEqual(@as(u32, 0), unit.read(msuinitr, 2) & init_reg.bit.suinit);
    try std.testing.expectEqual(@as(u32, 1), unit.setup.kicks);
}

test "the key is not kept either, so a read gives back no key to reuse" {
    var unit = block();
    defer unit.deinit();
    unit.write(msuinitr, 2, full_init);
    try std.testing.expectEqual(@as(u32, 0), unit.read(msuinitr, 2));
}

test "a store without the key kicks nothing" {
    var unit = block();
    defer unit.deinit();
    unit.write(msuinitr, 2, init_reg.bit.suinit);
    try std.testing.expectEqual(@as(u32, 0), unit.setup.kicks);
    try std.testing.expectEqual(@as(u32, 1), unit.setup.keyless);
}

test "an earlier keyed store does not vouch for a later one" {
    var unit = block();
    defer unit.deinit();
    unit.write(msuinitr, 2, full_init);
    unit.write(msuinitr, 2, init_reg.bit.suinit);
    try std.testing.expectEqual(@as(u32, 1), unit.setup.kicks);
    try std.testing.expectEqual(@as(u32, 1), unit.setup.keyless);
}

test "a byte store names less than the register, so it carries no key" {
    var unit = block();
    defer unit.deinit();
    unit.write(msuinitr, 1, 0x01);
    try std.testing.expectEqual(@as(u32, 0), unit.setup.kicks);
    try std.testing.expectEqual(@as(u32, 1), unit.setup.narrow_writes);
}

test "a word store is wider than the register and still carries the key" {
    var unit = block();
    defer unit.deinit();
    unit.write(msuinitr, 4, full_init);
    try std.testing.expectEqual(@as(u32, 1), unit.setup.kicks);
}

test "a keyed store without SUINIT sets up but kicks nothing" {
    var unit = block();
    defer unit.deinit();
    unit.write(msuinitr, 2, mram.field.key);
    try std.testing.expectEqual(@as(u32, 0), unit.setup.kicks);
    try std.testing.expectEqual(@as(u32, 0), unit.setup.keyless);
}

test "a block that never kicked stays quiet" {
    var unit = block();
    defer unit.deinit();
    try std.testing.expect(unit.quiet());
    unit.write(msuinitr, 2, full_init);
    try std.testing.expect(!unit.quiet());
}
