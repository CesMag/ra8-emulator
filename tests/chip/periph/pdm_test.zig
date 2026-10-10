//! Covers src/chip/periph/pdm.zig: the two start gates, the FIFO that has to
//! fill before a capture loop can drain it, and the registers dev shadows
//! that are status or triggers here.
const std = @import("std");
const pdm = @import("ra8").chip.periph.pdm;

fn channel(index: usize, offset: u32) u32 {
    return pdm.channelAddress(index) + offset;
}

test "a reset block reports nothing and holds no run state" {
    var unit = pdm.Pdm.init();
    try std.testing.expect(unit.quiet());
    try std.testing.expectEqual(@as(u32, 0), unit.read(pdm.win_base + pdm.off_csr, 4));
    try std.testing.expectEqual(@as(u32, 0), unit.read(channel(0, pdm.off_ddsr), 4));
}

test "PDCSTRTR starts the channels it names and PDCSR reads them back" {
    var unit = pdm.Pdm.init();
    unit.write(pdm.win_base + pdm.off_cstrtr, 4, 0b101);
    try std.testing.expectEqual(@as(u32, 0b101), unit.read(pdm.win_base + pdm.off_csr, 4));
    try std.testing.expect(unit.channels[0].running);
    try std.testing.expect(!unit.channels[1].running);
    try std.testing.expect(unit.channels[2].running);
}

test "PDCSTPTR stops only the channels it names" {
    var unit = pdm.Pdm.init();
    unit.write(pdm.win_base + pdm.off_cstrtr, 4, 0b111);
    unit.write(pdm.win_base + pdm.off_cstptr, 4, 0b010);
    try std.testing.expectEqual(@as(u32, 0b101), unit.read(pdm.win_base + pdm.off_csr, 4));
}

test "a trigger register keeps nothing: it reads zero, PDCSR carries the state" {
    var unit = pdm.Pdm.init();
    unit.write(pdm.win_base + pdm.off_cstrtr, 4, 0b001);
    // dev shadows the store and reads the trigger back as if it were status.
    try std.testing.expectEqual(@as(u32, 0), unit.read(pdm.win_base + pdm.off_cstrtr, 4));
    try std.testing.expectEqual(@as(u32, 0), unit.read(pdm.win_base + pdm.off_cstptr, 4));
    try std.testing.expectEqual(@as(u32, 1), unit.read(pdm.win_base + pdm.off_csr, 4));
}

test "PDCSR is status and refuses a store" {
    var unit = pdm.Pdm.init();
    unit.write(pdm.win_base + pdm.off_csr, 4, 0b111);
    try std.testing.expectEqual(@as(u32, 0), unit.read(pdm.win_base + pdm.off_csr, 4));
    for (&unit.channels) |*one| try std.testing.expect(!one.running);
}

test "a started channel with the read path disabled produces nothing" {
    var unit = pdm.Pdm.init();
    unit.write(pdm.win_base + pdm.off_cstrtr, 4, 0b001);
    unit.tick();
    try std.testing.expectEqual(@as(u32, 0), unit.read(channel(0, pdm.off_ddsr), 4));
    try std.testing.expectEqual(@as(u32, 0), unit.read(channel(0, pdm.off_ddrr), 4));
    try std.testing.expectEqual(@as(u32, 1), unit.channels[0].starved);
}

test "an enabled read path with no start produces nothing either" {
    var unit = pdm.Pdm.init();
    unit.write(channel(0, pdm.off_ddrcr), 4, pdm.field.datre);
    unit.tick();
    try std.testing.expectEqual(@as(u32, 0), unit.read(channel(0, pdm.off_ddsr), 4));
    try std.testing.expect(!unit.channels[0].live());
}

test "PDDSR reports the level the FIFO holds, not a pinned full depth" {
    var unit = pdm.Pdm.init();
    unit.write(pdm.win_base + pdm.off_cstrtr, 4, 0b001);
    unit.write(channel(0, pdm.off_ddrcr), 4, pdm.field.datre);
    unit.tick();
    // dev answers 32 here whatever has been produced.
    try std.testing.expectEqual(@as(u32, pdm.samples_per_tick), unit.read(channel(0, pdm.off_ddsr), 4));
    _ = unit.read(channel(0, pdm.off_ddrr), 4);
    try std.testing.expectEqual(@as(u32, pdm.samples_per_tick - 1), unit.read(channel(0, pdm.off_ddsr), 4));
}

test "a drain loop that outruns the microphone starves instead of being served" {
    var unit = pdm.Pdm.init();
    unit.write(pdm.win_base + pdm.off_cstrtr, 4, 0b001);
    unit.write(channel(0, pdm.off_ddrcr), 4, pdm.field.datre);
    unit.tick();
    for (0..pdm.samples_per_tick) |_| _ = unit.read(channel(0, pdm.off_ddrr), 4);
    try std.testing.expectEqual(@as(u32, 0), unit.read(channel(0, pdm.off_ddsr), 4));
    try std.testing.expectEqual(@as(u32, 0), unit.read(channel(0, pdm.off_ddrr), 4));
    try std.testing.expectEqual(@as(u32, pdm.samples_per_tick), unit.channels[0].read);
    try std.testing.expectEqual(@as(u32, 1), unit.channels[0].starved);
}

test "a capture loop too slow to keep up overruns the FIFO" {
    var unit = pdm.Pdm.init();
    unit.write(pdm.win_base + pdm.off_cstrtr, 4, 0b001);
    unit.write(channel(0, pdm.off_ddrcr), 4, pdm.field.datre);
    const ticks = pdm.fifo_depth / pdm.samples_per_tick + 1;
    for (0..ticks) |_| unit.tick();
    try std.testing.expectEqual(@as(u32, pdm.fifo_depth), unit.read(channel(0, pdm.off_ddsr), 4));
    try std.testing.expectEqual(@as(u32, pdm.samples_per_tick), unit.channels[0].overrun);
}

test "samples come out oldest first and inside the 20-bit field" {
    var unit = pdm.Pdm.init();
    unit.write(pdm.win_base + pdm.off_cstrtr, 4, 0b001);
    unit.write(channel(0, pdm.off_ddrcr), 4, pdm.field.datre);
    unit.tick();
    const first = unit.channels[0].fifo[0];
    const second = unit.channels[0].fifo[1];
    try std.testing.expectEqual(first, unit.read(channel(0, pdm.off_ddrr), 4));
    try std.testing.expectEqual(second, unit.read(channel(0, pdm.off_ddrr), 4));
    try std.testing.expectEqual(second, unit.channels[0].last);
    for (0..pdm.samples_per_tick) |index| {
        try std.testing.expectEqual(@as(u32, 0), unit.channels[0].fifo[index] & ~pdm.field.sample);
    }
}

test "the tone is not a degenerate toggle" {
    var unit = pdm.Pdm.init();
    unit.write(pdm.win_base + pdm.off_cstrtr, 4, 0b001);
    unit.write(channel(0, pdm.off_ddrcr), 4, pdm.field.datre);
    var seen = std.AutoHashMap(u32, void).init(std.testing.allocator);
    defer seen.deinit();
    for (0..4) |_| {
        unit.tick();
        for (0..pdm.samples_per_tick) |_| {
            try seen.put(unit.read(channel(0, pdm.off_ddrr), 4), {});
        }
    }
    try std.testing.expect(seen.count() > 16);
}

test "a stop drops what the FIFO was holding" {
    var unit = pdm.Pdm.init();
    unit.write(pdm.win_base + pdm.off_cstrtr, 4, 0b001);
    unit.write(channel(0, pdm.off_ddrcr), 4, pdm.field.datre);
    unit.tick();
    unit.write(pdm.win_base + pdm.off_cstptr, 4, 0b001);
    try std.testing.expectEqual(@as(u32, 0), unit.read(channel(0, pdm.off_ddsr), 4));
    try std.testing.expectEqual(@as(usize, 0), unit.channels[0].filled);
}

test "a byte store to PDDRCR keeps the bytes above it" {
    var unit = pdm.Pdm.init();
    unit.write(channel(1, pdm.off_ddrcr), 4, 0x5A5A_5A00);
    unit.write(channel(1, pdm.off_ddrcr), 1, pdm.field.datre);
    try std.testing.expect(unit.channels[1].read_enable);
    // dev drops a byte store at 0xE1 onto the word at 0xE0; here it misses.
    unit.write(channel(1, pdm.off_ddrcr) + 1, 1, 0x00);
    try std.testing.expect(unit.channels[1].read_enable);
}

test "channels are independent and an unmodelled register is shadowed" {
    var unit = pdm.Pdm.init();
    unit.write(pdm.win_base + pdm.off_cstrtr, 4, 0b010);
    unit.write(channel(1, pdm.off_ddrcr), 4, pdm.field.datre);
    unit.tick();
    try std.testing.expectEqual(@as(u32, pdm.samples_per_tick), unit.read(channel(1, pdm.off_ddsr), 4));
    try std.testing.expectEqual(@as(u32, 0), unit.read(channel(2, pdm.off_ddsr), 4));
    unit.write(channel(2, 0x40), 4, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), unit.read(channel(2, 0x40), 4));
    try std.testing.expectEqual(@as(u32, 0xBEEF), unit.read(channel(2, 0x40), 2));
}

test "an access past the window is refused" {
    var unit = pdm.Pdm.init();
    unit.write(pdm.win_base + pdm.win_span, 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), unit.read(pdm.win_base + pdm.win_span, 4));
    try std.testing.expect(unit.quiet());
}

/// Stage one known sample on a live channel, so a lane assertion is about
/// the cut and not about the tone.
fn staged(unit: *pdm.Pdm, sample: u32) void {
    unit.channels[0].running = true;
    unit.channels[0].read_enable = true;
    unit.channels[0].fifo[0] = sample;
    unit.channels[0].filled = 1;
}

test "a word read of PDDRR is the whole 20-bit sample" {
    var unit = pdm.Pdm.init();
    staged(&unit, 0xA_BCDE);
    try std.testing.expectEqual(@as(u32, 0xA_BCDE), unit.read(channel(0, pdm.off_ddrr), 4));
}

test "a narrow read of PDDRR is served the lanes it names" {
    var unit = pdm.Pdm.init();
    staged(&unit, 0xA_BCDE);
    try std.testing.expectEqual(@as(u32, 0xDE), unit.read(channel(0, pdm.off_ddrr), 1));
    staged(&unit, 0xA_BCDE);
    try std.testing.expectEqual(@as(u32, 0xBC), unit.read(channel(0, pdm.off_ddrr) + 1, 1));
    staged(&unit, 0xA_BCDE);
    try std.testing.expectEqual(@as(u32, 0x0A), unit.read(channel(0, pdm.off_ddrr) + 2, 1));
    // Bits 31:24 of a 20-bit sample are nothing at all.
    staged(&unit, 0xA_BCDE);
    try std.testing.expectEqual(@as(u32, 0x00), unit.read(channel(0, pdm.off_ddrr) + 3, 1));
}

test "the top halfword of PDDRR is bits 19:16, not the low half again" {
    var unit = pdm.Pdm.init();
    staged(&unit, 0xA_BCDE);
    try std.testing.expectEqual(@as(u32, 0xBCDE), unit.read(channel(0, pdm.off_ddrr), 2));
    staged(&unit, 0xA_BCDE);
    try std.testing.expectEqual(@as(u32, 0x000A), unit.read(channel(0, pdm.off_ddrr) + 2, 2));
}

test "every read of the port takes a sample, whatever lanes it names" {
    var unit = pdm.Pdm.init();
    unit.write(pdm.win_base + pdm.off_cstrtr, 4, 0b001);
    unit.write(channel(0, pdm.off_ddrcr), 4, pdm.field.datre);
    unit.tick();
    try std.testing.expectEqual(pdm.fifo_depth, unit.channels[0].filled);
    _ = unit.read(channel(0, pdm.off_ddrr) + 3, 1);
    _ = unit.read(channel(0, pdm.off_ddrr) + 2, 2);
    _ = unit.read(channel(0, pdm.off_ddrr), 4);
    try std.testing.expectEqual(pdm.fifo_depth - 3, unit.channels[0].filled);
    try std.testing.expectEqual(@as(u32, 3), unit.channels[0].read);
    try std.testing.expectEqual(@as(u32, 0), unit.channels[0].starved);
}

test "a narrow read of an empty port starves rather than inventing a lane" {
    var unit = pdm.Pdm.init();
    unit.write(pdm.win_base + pdm.off_cstrtr, 4, 0b001);
    unit.write(channel(0, pdm.off_ddrcr), 4, pdm.field.datre);
    try std.testing.expectEqual(@as(u32, 0), unit.read(channel(0, pdm.off_ddrr) + 2, 2));
    try std.testing.expectEqual(@as(u32, 1), unit.channels[0].starved);
}
