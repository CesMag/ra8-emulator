//! Covers src/chip/periph/xspi/reset.zig: RSTEN then RST, and what a reset
//! does to the write-enable latch through the engine.
const std = @import("std");
const ra8 = @import("ra8");

const xspi = ra8.chip.periph.xspi;
const nor_flash = ra8.components.nor_flash;
const reset = xspi.reset;

/// A one-byte 1S opcode, left-justified in CMD, no data.
fn single(opcode: u8) u32 {
    return 1 | (@as(u32, opcode) << 24);
}

/// The 8D form ra8_xspi.c sends: opcode in CMD[7:0], its complement in
/// CMD[15:8], CMDSIZE 2.
fn octal(opcode: u8) u32 {
    const word: u32 = @as(u32, opcode) | (@as(u32, ~opcode) << 8);
    return 2 | (word << xspi.descriptor.pos_cmd);
}

fn kick(unit: *xspi.Xspi, descriptor: u32) void {
    unit.write(xspi.bufferAddress(xspi.slot.cdt), 4, descriptor);
    unit.write(xspi.bufferAddress(xspi.slot.address), 4, 0);
    unit.write(xspi.win_base + xspi.off_cdctl0, 4, xspi.field.trreq);
}

fn status(unit: *xspi.Xspi) u32 {
    kick(unit, single(0x05) | (1 << xspi.descriptor.pos_datasize));
    return unit.read(xspi.bufferAddress(xspi.slot.data0), 4);
}

test "RST straight after RSTEN resets" {
    var sequence = reset.Sequence{};
    try std.testing.expect(!sequence.step(reset.opcode.enable));
    try std.testing.expect(sequence.step(reset.opcode.reset));
    try std.testing.expectEqual(@as(u32, 1), sequence.resets);
    try std.testing.expectEqual(@as(u32, 0), sequence.ignored);
}

test "a bare RST is ignored and counted" {
    var sequence = reset.Sequence{};
    try std.testing.expect(!sequence.step(reset.opcode.reset));
    try std.testing.expectEqual(@as(u32, 0), sequence.resets);
    try std.testing.expectEqual(@as(u32, 1), sequence.ignored);
}

test "any command between RSTEN and RST disarms the enable" {
    var sequence = reset.Sequence{};
    _ = sequence.step(reset.opcode.enable);
    _ = sequence.step(0x05);
    try std.testing.expect(!sequence.step(reset.opcode.reset));
    try std.testing.expectEqual(@as(u32, 1), sequence.ignored);
}

test "a taken RST spends the enable" {
    var sequence = reset.Sequence{};
    _ = sequence.step(reset.opcode.enable);
    _ = sequence.step(reset.opcode.reset);
    try std.testing.expect(!sequence.step(reset.opcode.reset));
    try std.testing.expectEqual(@as(u32, 1), sequence.resets);
    try std.testing.expectEqual(@as(u32, 1), sequence.ignored);
}

test "a 1S reset drops the write-enable latch" {
    var part = nor_flash.Flash.init(std.testing.allocator);
    defer part.deinit();
    var unit = xspi.Xspi{ .part = part.nor() };

    kick(&unit, single(0x06));
    try std.testing.expectEqual(xspi.status.wel, status(&unit));
    kick(&unit, single(reset.opcode.enable));
    kick(&unit, single(reset.opcode.reset));
    try std.testing.expectEqual(@as(u32, 0), status(&unit));
    try std.testing.expectEqual(@as(u32, 1), unit.resetting.resets);
}

test "an 8D reset drops the latch too" {
    var part = nor_flash.Flash.init(std.testing.allocator);
    defer part.deinit();
    var unit = xspi.Xspi{ .part = part.nor() };

    kick(&unit, single(0x06));
    kick(&unit, octal(reset.opcode.enable));
    kick(&unit, octal(reset.opcode.reset));
    try std.testing.expectEqual(@as(u32, 0), status(&unit));
}

test "a bare RST leaves the latch set" {
    var part = nor_flash.Flash.init(std.testing.allocator);
    defer part.deinit();
    var unit = xspi.Xspi{ .part = part.nor() };

    kick(&unit, single(0x06));
    kick(&unit, single(reset.opcode.reset));
    try std.testing.expectEqual(xspi.status.wel, status(&unit));
    try std.testing.expectEqual(@as(u32, 1), unit.resetting.ignored);
}

test "a reset completes like any other command" {
    var part = nor_flash.Flash.init(std.testing.allocator);
    defer part.deinit();
    var unit = xspi.Xspi{ .part = part.nor() };

    kick(&unit, single(reset.opcode.enable));
    try std.testing.expectEqual(xspi.field.cmdcmp, unit.read(xspi.win_base + xspi.off_ints, 4));
}
