//! MENTRYR: what carries the key, and what the pause bit does.
const std = @import("std");
const ra8 = @import("ra8");

const entry_reg = ra8.chip.periph.mram_entry;
const field = ra8.chip.periph.mram_regs.field;

test "a keyed word store enters program/erase mode" {
    var unit: entry_reg.Entry = .{};
    try std.testing.expectEqual(entry_reg.Outcome.entered, unit.write(0, 2, 0xAA80));
    try std.testing.expect(unit.in_pe_mode);
    try std.testing.expectEqual(field.mentry, unit.status());
}

test "the key never reads back" {
    var unit: entry_reg.Entry = .{};
    _ = unit.write(0, 2, 0xAA80);
    try std.testing.expectEqual(@as(u32, 0), unit.status() & field.key_mask);
}

test "the keyed pause pattern raises PCKA and it reads back" {
    var unit: entry_reg.Entry = .{};
    _ = unit.write(0, 2, 0xAA80);
    try std.testing.expectEqual(entry_reg.Outcome.entered, unit.write(0, 2, 0xAAC0));
    try std.testing.expect(unit.paused);
    try std.testing.expectEqual(field.mentry | field.pcka, unit.status());
}

test "the keyed resume pattern drops PCKA and stays in the mode" {
    var unit: entry_reg.Entry = .{};
    _ = unit.write(0, 2, 0xAAC0);
    _ = unit.write(0, 2, 0xAA80);
    try std.testing.expect(unit.in_pe_mode);
    try std.testing.expect(!unit.paused);
    try std.testing.expectEqual(field.mentry, unit.status());
}

test "leaving program/erase mode drops a standing pause" {
    var unit: entry_reg.Entry = .{};
    _ = unit.write(0, 2, 0xAAC0);
    try std.testing.expectEqual(entry_reg.Outcome.left, unit.write(0, 2, 0xAA00));
    try std.testing.expect(!unit.paused);
    try std.testing.expectEqual(@as(u32, 0), unit.status());
}

test "a pause bit with no mode bit is not program/erase mode" {
    var unit: entry_reg.Entry = .{};
    try std.testing.expectEqual(entry_reg.Outcome.left, unit.write(0, 2, 0xAA40));
    try std.testing.expect(!unit.in_pe_mode);
    try std.testing.expectEqual(@as(u32, 0), unit.status());
}

test "a byte store carries no key and moves nothing" {
    var unit: entry_reg.Entry = .{};
    _ = unit.write(0, 2, 0xAA80);
    try std.testing.expectEqual(entry_reg.Outcome.refused, unit.write(0, 1, 0xC0));
    try std.testing.expect(!unit.paused);
    try std.testing.expectEqual(@as(u32, 1), unit.narrow_writes);
}

test "a keyless word store is counted and moves nothing" {
    var unit: entry_reg.Entry = .{};
    try std.testing.expectEqual(entry_reg.Outcome.refused, unit.write(0, 4, 0x0000_00C0));
    try std.testing.expect(!unit.in_pe_mode);
    try std.testing.expectEqual(@as(u32, 1), unit.keyless);
    try std.testing.expect(!unit.quiet());
}

test "a word store of the halfword register still carries the key" {
    var unit: entry_reg.Entry = .{};
    try std.testing.expectEqual(entry_reg.Outcome.entered, unit.write(0, 4, 0x0000_AAC0));
    try std.testing.expect(unit.paused);
}
