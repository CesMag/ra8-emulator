//! Tests for src/chip/periph/crc.zig.
const std = @import("std");
const ra8 = @import("ra8");
const periph = ra8.chip.periph.registry;
const mod = ra8.chip.periph.crc;

const Crc = mod.Crc;
const Gps = mod.Gps;
const dorclr = mod.dorclr;
const off_cr0 = mod.off_cr0;
const off_cr1 = mod.off_cr1;
const off_dir = mod.off_dir;
const off_dor = mod.off_dor;
const regAddress = mod.regAddress;

const check = "123456789";

fn feedSlice(unit: *Crc, bytes: []const u8) void {
    for (bytes) |byte| unit.write(regAddress(off_dir), 1, byte);
}
test "CRC-32 over the check string matches the standard remainder" {
    var unit = Crc.init();
    unit.write(regAddress(off_cr0), 1, @backingInt(Gps.crc32));
    // The unit applies no seed: the driver pre-seeds CRCDOR and inverts the
    // readback, so the raw remainder here is the complement of 0xCBF4_3926.
    unit.write(regAddress(off_dor), 4, 0xFFFF_FFFF);
    feedSlice(&unit, check);
    try std.testing.expectEqual(@as(u32, 0x340B_C6D9), unit.read(regAddress(off_dor), 4));
    try std.testing.expectEqual(@as(u32, 0xCBF4_3926), unit.read(regAddress(off_dor), 4) ^ 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 9), unit.bytes);
}

test "CRC-32C uses the Castagnoli polynomial, not CRC-32" {
    var unit = Crc.init();
    unit.write(regAddress(off_cr0), 1, @backingInt(Gps.crc32c));
    unit.write(regAddress(off_dor), 4, 0xFFFF_FFFF);
    feedSlice(&unit, check);
    try std.testing.expectEqual(@as(u32, 0xE306_9283), unit.read(regAddress(off_dor), 4) ^ 0xFFFF_FFFF);
}

test "the reflected and MSB-first modes each hit their standard check value" {
    var arc = Crc.init();
    arc.write(regAddress(off_cr0), 1, @backingInt(Gps.crc16));
    feedSlice(&arc, check);
    try std.testing.expectEqual(@as(u32, 0xBB3D), arc.read(regAddress(off_dor), 4));

    var ccitt = Crc.init();
    ccitt.write(regAddress(off_cr0), 1, @backingInt(Gps.ccitt));
    feedSlice(&ccitt, check);
    try std.testing.expectEqual(@as(u32, 0x31C3), ccitt.read(regAddress(off_dor), 4));

    var small = Crc.init();
    small.write(regAddress(off_cr0), 1, @backingInt(Gps.crc8));
    feedSlice(&small, check);
    try std.testing.expectEqual(@as(u32, 0xF4), small.read(regAddress(off_dor), 4));
}

test "a word feed folds four bytes LSB-first, the order the driver packs them" {
    var byte_fed = Crc.init();
    byte_fed.write(regAddress(off_cr0), 1, @backingInt(Gps.crc32));
    byte_fed.write(regAddress(off_dor), 4, 0xFFFF_FFFF);
    feedSlice(&byte_fed, check);

    var word_fed = Crc.init();
    word_fed.write(regAddress(off_cr0), 1, @backingInt(Gps.crc32));
    word_fed.write(regAddress(off_dor), 4, 0xFFFF_FFFF);
    word_fed.write(regAddress(off_dir), 4, 0x3433_3231); // "1234"
    word_fed.write(regAddress(off_dir), 4, 0x3837_3635); // "5678"
    word_fed.write(regAddress(off_dir), 1, '9');

    try std.testing.expectEqual(byte_fed.dor, word_fed.dor);
    try std.testing.expectEqual(@as(u32, 9), word_fed.bytes);
}

test "DORCLR clears the remainder and GPS=0 calculates nothing" {
    var unit = Crc.init();
    unit.write(regAddress(off_cr0), 1, @backingInt(Gps.crc32));
    feedSlice(&unit, "abc");
    try std.testing.expect(unit.dor != 0);

    unit.write(regAddress(off_cr0), 1, @backingInt(Gps.crc32) | dorclr);
    try std.testing.expectEqual(@as(u32, 0), unit.read(regAddress(off_dor), 4));

    unit.write(regAddress(off_cr0), 1, @backingInt(Gps.none));
    feedSlice(&unit, "abc");
    try std.testing.expectEqual(@as(u32, 0), unit.read(regAddress(off_dor), 4));
    // The bytes still went in, even though nothing folded them.
    try std.testing.expectEqual(@as(u32, 6), unit.bytes);
}

test "CRCDOR is seedable byte by byte and reads back through its aliases" {
    var unit = Crc.init();
    unit.write(regAddress(off_dor), 4, 0xAABB_CCDD);
    try std.testing.expectEqual(@as(u32, 0xDD), unit.read(regAddress(off_dor), 1));
    try std.testing.expectEqual(@as(u32, 0xAABB), unit.read(regAddress(off_dor + 2), 2));

    unit.write(regAddress(off_dor + 1), 1, 0x11);
    try std.testing.expectEqual(@as(u32, 0xAABB_11DD), unit.read(regAddress(off_dor), 4));
    unit.write(regAddress(off_dor + 2), 2, 0x1234);
    try std.testing.expectEqual(@as(u32, 0x1234_11DD), unit.read(regAddress(off_dor), 4));
}

test "the control registers read back and CRCDIR reads zero" {
    var unit = Crc.init();
    unit.write(regAddress(off_cr0), 1, 0x04);
    unit.write(regAddress(off_cr1), 1, 0x80);
    try std.testing.expectEqual(@as(u32, 0x04), unit.read(regAddress(off_cr0), 1));
    try std.testing.expectEqual(@as(u32, 0x80), unit.read(regAddress(off_cr1), 1));
    try std.testing.expectEqual(@as(u32, 0), unit.read(regAddress(off_dir), 4));
    try std.testing.expect(unit.quiet());
}

test "the unit answers on the bus, in both windows, once it is ungated" {
    var bus = periph.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var unit = Crc.init();
    try bus.add(unit.block());

    bus.write(regAddress(off_cr0), 1, @backingInt(Gps.crc32));
    bus.write(regAddress(off_dor), 4, 0xFFFF_FFFF);
    bus.write(periph.ns_base + (regAddress(off_dir) - periph.base), 4, 0x3433_3231);
    bus.write(regAddress(off_dir), 4, 0x3837_3635);
    bus.write(regAddress(off_dir), 1, '9');
    try std.testing.expectEqual(@as(u32, 0xCBF4_3926), bus.read(regAddress(off_dor), 4) ^ 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(usize, 0), bus.unmodelledAddresses());
}

test "GPS is read back out of CRCCR0, masked to its three bits" {
    var unit = Crc.init();
    unit.write(regAddress(off_cr0), 1, 0xFD); // DORCLR set, LMS set, GPS=5
    try std.testing.expectEqual(Gps.crc32c, unit.gps());
    // Everything but DORCLR survives the store; DORCLR was spent on the way in.
    try std.testing.expectEqual(@as(u32, 0x7D), unit.read(regAddress(off_cr0), 1));
    try std.testing.expectEqual(@as(u32, 1), unit.cleared);
}

test "DORCLR does not stay in the shadow, so a readback is the settings alone" {
    var unit = Crc.init();
    unit.write(regAddress(off_cr0), 1, @backingInt(Gps.crc32) | dorclr);
    // ra8_crc_get_status reads the whole byte: 0x04 on the bench, not 0x84.
    try std.testing.expectEqual(@as(u32, 0x04), unit.read(regAddress(off_cr0), 1));
    try std.testing.expectEqual(Gps.crc32, unit.gps());
}

test "ra8_crc_reset's read-modify-write still clears, and keeps the polynomial" {
    var unit = Crc.init();
    unit.write(regAddress(off_cr0), 1, @backingInt(Gps.crc32));
    unit.write(regAddress(off_dor), 4, 0xFFFF_FFFF);

    const readback: u8 = @truncate(unit.read(regAddress(off_cr0), 1));
    unit.write(regAddress(off_cr0), 1, readback | dorclr);

    try std.testing.expectEqual(@as(u32, 0), unit.read(regAddress(off_dor), 4));
    try std.testing.expectEqual(Gps.crc32, unit.gps());
    try std.testing.expectEqual(@as(u32, 1), unit.cleared);
}

test "a read-modify-write that does not name DORCLR leaves the remainder alone" {
    var unit = Crc.init();
    unit.write(regAddress(off_cr0), 1, @backingInt(Gps.crc32) | dorclr);
    unit.write(regAddress(off_dor), 4, 0xFFFF_FFFF);

    // ra8_crc_set_bit_order: fold LMS in on top of whatever CRCCR0 reads.
    const readback: u8 = @truncate(unit.read(regAddress(off_cr0), 1));
    unit.write(regAddress(off_cr0), 1, readback | 0x40);

    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), unit.read(regAddress(off_dor), 4));
    try std.testing.expectEqual(@as(u32, 0x44), unit.read(regAddress(off_cr0), 1));
    // Only the init pulse was ever asked for.
    try std.testing.expectEqual(@as(u32, 1), unit.cleared);
}

test "a running remainder survives a bit-order store mid-calculation" {
    var straight = Crc.init();
    straight.write(regAddress(off_cr0), 1, @backingInt(Gps.crc32) | dorclr);
    straight.write(regAddress(off_dor), 4, 0xFFFF_FFFF);
    feedSlice(&straight, check);

    var interrupted = Crc.init();
    interrupted.write(regAddress(off_cr0), 1, @backingInt(Gps.crc32) | dorclr);
    interrupted.write(regAddress(off_dor), 4, 0xFFFF_FFFF);
    feedSlice(&interrupted, check[0..4]);
    const readback: u8 = @truncate(interrupted.read(regAddress(off_cr0), 1));
    interrupted.write(regAddress(off_cr0), 1, readback | 0x40);
    feedSlice(&interrupted, check[4..]);

    try std.testing.expectEqual(straight.dor, interrupted.dor);
    try std.testing.expectEqual(@as(u32, 9), interrupted.bytes);
}

test "a unit that only ever had its remainder cleared still reports" {
    var unit = Crc.init();
    try std.testing.expect(unit.quiet());
    unit.write(regAddress(off_cr0), 1, @backingInt(Gps.crc32) | dorclr);
    try std.testing.expect(!unit.quiet());
    try std.testing.expectEqual(@as(u32, 0), unit.bytes);
}
