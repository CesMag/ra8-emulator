//! Covers src/chip/periph/dtc/dtc.zig: the control window and the activation path that
//! turns an interrupt into a copy the CPU never sees.
const std = @import("std");
const ra8 = @import("ra8");
const dtc = ra8.chip.periph.dtc;
const icu = ra8.chip.periph.icu;
const xfer = ra8.chip.periph.dtc.xfer;

/// The bytes of a run, and a handle onto them. The controller takes its
/// memory by value the way it takes a real engine, so the handle holds a
/// pointer: a copy of it still reaches the same storage.
const Cells = struct {
    base: u32 = 0x2000_0000,
    bytes: [512]u8 = @splat(0),
};

/// A stand-in for the machine's memory: one flat window, with the four calls
/// the controller makes of a core. A real engine is the other implementation;
/// this one keeps a descriptor test off the core.
const Memory = struct {
    cells: *Cells,

    fn window(self: Memory, address: u32, span: u32) ?[]u8 {
        if (address < self.cells.base) return null;
        const start = address - self.cells.base;
        if (start + span > self.cells.bytes.len) return null;
        return self.cells.bytes[start .. start + span];
    }

    pub fn read(self: Memory, address: u32, into: []u8) !void {
        const from = self.window(address, @intCast(into.len)) orelse return error.Unmapped;
        @memcpy(into, from);
    }

    pub fn write(self: Memory, address: u32, bytes: []const u8) !void {
        const into = self.window(address, @intCast(bytes.len)) orelse return error.Unmapped;
        @memcpy(into, bytes);
    }

    pub fn readWord(self: Memory, address: u32) !u32 {
        var word: [4]u8 = undefined;
        try self.read(address, &word);
        return std.mem.readInt(u32, &word, .little);
    }

    pub fn writeWord(self: Memory, address: u32, value: u32) !void {
        var word: [4]u8 = undefined;
        std.mem.writeInt(u32, &word, value, .little);
        try self.write(address, &word);
    }

    pub fn byteAt(self: Memory, address: u32) u8 {
        return self.cells.bytes[address - self.cells.base];
    }

    pub fn poke(self: Memory, address: u32, value: u8) void {
        self.cells.bytes[address - self.cells.base] = value;
    }
};

const vector_base: u32 = 0x2000_0000;
const ti_at: u32 = 0x2000_0100;
const source_at: u32 = 0x2000_0140;
const dest_at: u32 = 0x2000_0180;
const event: u16 = 0x0CC;
const slot: usize = 7;

fn mode(mra: u8, mrb: u8) u32 {
    return (@as(u32, mra) << 24) | (@as(u32, mrb) << 16);
}

/// A byte copy, both addresses incrementing, interrupt on the last transfer.
const byte_copy = mode(0b0000_1000, 0b0000_1000);

/// Put a vector-table entry and a descriptor in memory and hand back a
/// controller pointed at them, with the ICU slot linked and DTCE set.
fn scene(memory: Memory, links: *icu.Icu, mr: u32, crb: u16, cra: u16) dtc.Dtc {
    memory.writeWord(dtc.entryAddress(vector_base, slot), ti_at) catch unreachable;
    memory.writeWord(ti_at + xfer.off.mr, mr) catch unreachable;
    memory.writeWord(ti_at + xfer.off.sar, source_at) catch unreachable;
    memory.writeWord(ti_at + xfer.off.dar, dest_at) catch unreachable;
    memory.writeWord(ti_at + xfer.off.counts, @as(u32, crb) | (@as(u32, cra) << 16)) catch unreachable;
    links.* = icu.Icu.init();
    links.links[slot] = event | icu.field.dtce;
    var unit = dtc.Dtc.init();
    unit.write(dtc.win_base + dtc.off.dtcvbr, 4, vector_base);
    unit.write(dtc.win_base + dtc.off.dtcst, 1, dtc.field.start);
    return unit;
}

test "the control registers read back what the driver wrote" {
    var unit = dtc.Dtc.init();
    unit.write(dtc.win_base + dtc.off.dtccr, 1, 0x08);
    unit.write(dtc.win_base + dtc.off.dtcvbr, 4, 0x2000_4000);
    unit.write(dtc.win_base + dtc.off.dtcst, 1, 0x01);
    try std.testing.expectEqual(@as(u32, 0x08), unit.read(dtc.win_base + dtc.off.dtccr, 1));
    try std.testing.expectEqual(@as(u32, 0x2000_4000), unit.read(dtc.win_base + dtc.off.dtcvbr, 4));
    try std.testing.expectEqual(@as(u32, 0x01), unit.read(dtc.win_base + dtc.off.dtcst, 1));
    try std.testing.expect(unit.started());
}

test "DTCSTS is the controller's to write, not the firmware's" {
    var unit = dtc.Dtc.init();
    unit.write(dtc.win_base + dtc.off.dtcsts, 2, 0xFFFF);
    try std.testing.expectEqual(@as(u32, 0), unit.read(dtc.win_base + dtc.off.dtcsts, 2));
}

test "an event no slot links with DTCE is not the controller's" {
    var cells = Cells{};
    const memory = Memory{ .cells = &cells };
    var links = icu.Icu.init();
    var unit = scene(memory, &links, byte_copy, 0, 4);
    links.links[slot] = event; // linked, but DTCE clear: an ordinary interrupt
    try std.testing.expectEqual(@as(?dtc.Outcome, null), unit.activate(memory, &links, event));
    try std.testing.expectEqual(@as(u32, 0), unit.refused);
}

test "one activation moves one unit and writes the descriptor back" {
    var cells = Cells{};
    const memory = Memory{ .cells = &cells };
    var links = icu.Icu.init();
    var unit = scene(memory, &links, byte_copy, 0, 4);
    memory.poke(source_at, 0xA5);
    const moved = unit.activate(memory, &links, event).?;
    try std.testing.expectEqual(@as(u32, 1), moved.units);
    try std.testing.expectEqual(@as(u32, 1), moved.bytes);
    try std.testing.expectEqual(@as(u8, 0xA5), memory.byteAt(dest_at));
    try std.testing.expectEqual(@as(u32, source_at + 1), try memory.readWord(ti_at + xfer.off.sar));
    try std.testing.expectEqual(@as(u32, dest_at + 1), try memory.readWord(ti_at + xfer.off.dar));
    try std.testing.expectEqual(@as(u32, 3 << 16), try memory.readWord(ti_at + xfer.off.counts));
}

test "the core hears nothing while the descriptor still has units left" {
    var cells = Cells{};
    const memory = Memory{ .cells = &cells };
    var links = icu.Icu.init();
    var unit = scene(memory, &links, byte_copy, 0, 4);
    const moved = unit.activate(memory, &links, event).?;
    try std.testing.expect(!moved.interrupt);
    try std.testing.expect(!moved.complete);
    try std.testing.expectEqual(@as(u32, 1), unit.suppressed);
}

test "MRB.DISEL gives the core every transfer" {
    var cells = Cells{};
    const memory = Memory{ .cells = &cells };
    var links = icu.Icu.init();
    var unit = scene(memory, &links, mode(0b0000_1000, 0b0010_1000), 0, 4);
    const moved = unit.activate(memory, &links, event).?;
    try std.testing.expect(moved.interrupt);
    try std.testing.expectEqual(@as(u32, 0), unit.suppressed);
}

test "the last unit finishes the descriptor and takes DTCE down" {
    var cells = Cells{};
    const memory = Memory{ .cells = &cells };
    var links = icu.Icu.init();
    var unit = scene(memory, &links, byte_copy, 0, 1);
    const moved = unit.activate(memory, &links, event).?;
    try std.testing.expect(moved.complete);
    try std.testing.expect(moved.interrupt);
    try std.testing.expectEqual(@as(u32, 1), unit.completions);
    try std.testing.expectEqual(@as(?usize, null), links.dtcSlotFor(event));
    try std.testing.expectEqual(event, links.links[slot] & icu.field.iels);
}

test "a spent descriptor is refused rather than run again" {
    var cells = Cells{};
    const memory = Memory{ .cells = &cells };
    var links = icu.Icu.init();
    var unit = scene(memory, &links, byte_copy, 0, 0);
    try std.testing.expectEqual(@as(?dtc.Outcome, null), unit.activate(memory, &links, event));
    try std.testing.expectEqual(dtc.Refusal.exhausted, unit.last_refusal.?);
}

test "a controller that was never started moves nothing" {
    var cells = Cells{};
    const memory = Memory{ .cells = &cells };
    var links = icu.Icu.init();
    var unit = scene(memory, &links, byte_copy, 0, 4);
    unit.write(dtc.win_base + dtc.off.dtcst, 1, 0);
    memory.poke(source_at, 0x5A);
    try std.testing.expectEqual(@as(?dtc.Outcome, null), unit.activate(memory, &links, event));
    try std.testing.expectEqual(dtc.Refusal.stopped, unit.last_refusal.?);
    try std.testing.expectEqual(@as(u8, 0), memory.byteAt(dest_at));
}

test "no vector base and no table entry are both refused as unprogrammed" {
    var cells = Cells{};
    const memory = Memory{ .cells = &cells };
    var links = icu.Icu.init();
    var unit = scene(memory, &links, byte_copy, 0, 4);
    unit.write(dtc.win_base + dtc.off.dtcvbr, 4, 0);
    try std.testing.expectEqual(@as(?dtc.Outcome, null), unit.activate(memory, &links, event));
    try std.testing.expectEqual(dtc.Refusal.unprogrammed, unit.last_refusal.?);

    unit.write(dtc.win_base + dtc.off.dtcvbr, 4, vector_base);
    try memory.writeWord(dtc.entryAddress(vector_base, slot), 0);
    try std.testing.expectEqual(@as(?dtc.Outcome, null), unit.activate(memory, &links, event));
    try std.testing.expectEqual(dtc.Refusal.unprogrammed, unit.last_refusal.?);
}

test "the privilege bit of a table entry is not part of the address" {
    var cells = Cells{};
    const memory = Memory{ .cells = &cells };
    var links = icu.Icu.init();
    var unit = scene(memory, &links, byte_copy, 0, 2);
    try memory.writeWord(dtc.entryAddress(vector_base, slot), ti_at | 1);
    memory.poke(source_at, 0x3C);
    const moved = unit.activate(memory, &links, event).?;
    try std.testing.expectEqual(@as(u32, 1), moved.bytes);
    try std.testing.expectEqual(@as(u8, 0x3C), memory.byteAt(dest_at));
}

test "a descriptor this model will not invent a transfer for is named" {
    var cells = Cells{};
    const memory = Memory{ .cells = &cells };
    var links = icu.Icu.init();
    var unit = scene(memory, &links, mode(0b0100_1000, 0b0000_1000), 0, 4);
    try std.testing.expectEqual(@as(?dtc.Outcome, null), unit.activate(memory, &links, event));
    try std.testing.expectEqual(xfer.Unsupported.repeat_mode, unit.last_refusal.?.unsupported);
    try std.testing.expectEqualStrings("repeat_mode", dtc.refusalName(unit.last_refusal.?));
}

test "one block activation moves a whole block and spends a block count" {
    var cells = Cells{};
    const memory = Memory{ .cells = &cells };
    var links = icu.Icu.init();
    var unit = scene(memory, &links, mode(0b1000_1000, 0b0000_1000), 2, 0x0404);
    for (0..4) |index| memory.poke(source_at + @as(u32, @intCast(index)), @intCast(index + 1));
    const moved = unit.activate(memory, &links, event).?;
    try std.testing.expectEqual(@as(u32, 4), moved.units);
    try std.testing.expectEqual(@as(u32, 4), moved.bytes);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 1, 2, 3, 4 },
        cells.bytes[dest_at - cells.base ..][0..4],
    );
    try std.testing.expectEqual(@as(u32, 0x0404_0001), try memory.readWord(ti_at + xfer.off.counts));
}

test "a fixed destination takes the whole run, the way a data register does" {
    var cells = Cells{};
    const memory = Memory{ .cells = &cells };
    var links = icu.Icu.init();
    var unit = scene(memory, &links, mode(0b1000_1000, 0), 1, 0x0303);
    for (0..3) |index| memory.poke(source_at + @as(u32, @intCast(index)), @intCast(0x10 + index));
    _ = unit.activate(memory, &links, event).?;
    try std.testing.expectEqual(@as(u8, 0x12), memory.byteAt(dest_at));
    try std.testing.expectEqual(@as(u8, 0), memory.byteAt(dest_at + 1));
}

test "a word copy moves four bytes a unit" {
    var cells = Cells{};
    const memory = Memory{ .cells = &cells };
    var links = icu.Icu.init();
    var unit = scene(memory, &links, mode(0b0010_1000, 0b0000_1000), 0, 2);
    try memory.writeWord(source_at, 0xDEAD_BEEF);
    const moved = unit.activate(memory, &links, event).?;
    try std.testing.expectEqual(@as(u32, 1), moved.units);
    try std.testing.expectEqual(@as(u32, 4), moved.bytes);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), try memory.readWord(dest_at));
}

test "a descriptor pointing outside memory is refused, not half copied" {
    var cells = Cells{};
    const memory = Memory{ .cells = &cells };
    var links = icu.Icu.init();
    var unit = scene(memory, &links, byte_copy, 0, 4);
    try memory.writeWord(ti_at + xfer.off.sar, 0x9000_0000);
    try std.testing.expectEqual(@as(?dtc.Outcome, null), unit.activate(memory, &links, event));
    try std.testing.expectEqual(dtc.Refusal.unreadable, unit.last_refusal.?);
}

test "an untouched controller stays out of the report" {
    var unit = dtc.Dtc.init();
    try std.testing.expect(unit.quiet());
    unit.write(dtc.win_base + dtc.off.dtcvbr, 4, vector_base);
    try std.testing.expect(!unit.quiet());
}

test "the last transfer's vector number lands in DTCSTS" {
    var cells = Cells{};
    const memory = Memory{ .cells = &cells };
    var links = icu.Icu.init();
    var unit = scene(memory, &links, byte_copy, 0, 4);
    _ = unit.activate(memory, &links, event).?;
    try std.testing.expectEqual(
        @as(u32, icu.exceptionFor(slot)),
        unit.read(dtc.win_base + dtc.off.dtcsts, 2),
    );
}

/// Block mode, byte units, both addresses incrementing, interrupt on the last
/// block. CRAH is the block size, so it is set per test.
const block_copy = mode(0b1000_1000, 0b0000_1000);

/// The window the Memory above serves ends here, so a block aimed at the last
/// bytes of it is refused partway through.
const past_window: u32 = 0x2000_0200;

/// A short-block scene laid out clear of the descriptor, the vector table and
/// each other: 0x30 bytes a block, of which only the first 0x20 have anywhere
/// to go. Overlapping the two would have the copy read what it just wrote.
const short_source: u32 = 0x2000_0040;
const short_dest: u32 = 0x2000_01E0;
const short_block: u32 = 0x30;
const short_fits: u32 = 0x20;

/// scene() with the two addresses moved and a block size that runs off the
/// end of the window.
fn shortScene(memory: Memory, links: *icu.Icu) dtc.Dtc {
    const unit = scene(memory, links, block_copy, 2, @intCast(short_block << 8));
    memory.writeWord(ti_at + xfer.off.sar, short_source) catch unreachable;
    memory.writeWord(ti_at + xfer.off.dar, short_dest) catch unreachable;
    return unit;
}

test "a block that walks off the end keeps the bytes that landed" {
    var cells = Cells{};
    const memory = Memory{ .cells = &cells };
    var links = icu.Icu.init();
    var unit = shortScene(memory, &links);
    memory.poke(short_source, 0x11);
    memory.poke(short_source + short_fits - 1, 0x22);

    try std.testing.expectEqual(@as(?dtc.Outcome, null), unit.activate(memory, &links, event));
    try std.testing.expectEqual(dtc.Refusal.unreadable, unit.last_refusal.?);
    try std.testing.expectEqual(@as(u8, 0x11), memory.byteAt(short_dest));
    try std.testing.expectEqual(@as(u8, 0x22), memory.byteAt(short_dest + short_fits - 1));
}

test "a short block books the bytes it moved and still leaves DTCE up" {
    var cells = Cells{};
    const memory = Memory{ .cells = &cells };
    var links = icu.Icu.init();
    var unit = shortScene(memory, &links);
    _ = unit.activate(memory, &links, event);
    try std.testing.expectEqual(@as(u64, short_fits), unit.units);
    try std.testing.expectEqual(@as(u64, short_fits), unit.bytes);
    try std.testing.expectEqual(@as(u32, 0), unit.activations);
    try std.testing.expectEqual(@as(u32, 0), unit.completions);
    try std.testing.expect(links.dtcSlotFor(event) != null);
}

test "a short block leaves the descriptor where the copy stopped" {
    var cells = Cells{};
    const memory = Memory{ .cells = &cells };
    var links = icu.Icu.init();
    var unit = shortScene(memory, &links);
    _ = unit.activate(memory, &links, event);
    try std.testing.expectEqual(short_source + short_fits, try memory.readWord(ti_at + xfer.off.sar));
    try std.testing.expectEqual(past_window, try memory.readWord(ti_at + xfer.off.dar));
    // The block never completed, so neither count has been paid.
    try std.testing.expectEqual(@as(u32, 2 | (short_block << 24)), try memory.readWord(ti_at + xfer.off.counts));
}

test "the next activation carries on rather than copying the same bytes again" {
    var cells = Cells{};
    const memory = Memory{ .cells = &cells };
    var links = icu.Icu.init();
    var unit = shortScene(memory, &links);
    _ = unit.activate(memory, &links, event);
    // Still nowhere to put them, so the second activation moves nothing at
    // all: the destination is already past the end, not back at the start.
    _ = unit.activate(memory, &links, event);
    try std.testing.expectEqual(@as(u64, short_fits), unit.units);
    try std.testing.expectEqual(@as(u32, 2), unit.refused);
    try std.testing.expectEqual(past_window, try memory.readWord(ti_at + xfer.off.dar));
}

test "a normal-mode unit memory refuses moves nothing and spends nothing" {
    var cells = Cells{};
    const memory = Memory{ .cells = &cells };
    var links = icu.Icu.init();
    var unit = scene(memory, &links, byte_copy, 0, 4);
    memory.writeWord(ti_at + xfer.off.dar, 0x3000_0000) catch unreachable;

    try std.testing.expectEqual(@as(?dtc.Outcome, null), unit.activate(memory, &links, event));
    try std.testing.expectEqual(dtc.Refusal.unreadable, unit.last_refusal.?);
    try std.testing.expectEqual(@as(u64, 0), unit.bytes);
    try std.testing.expectEqual(@as(u32, source_at), try memory.readWord(ti_at + xfer.off.sar));
    try std.testing.expectEqual(@as(u32, 4 << 16), try memory.readWord(ti_at + xfer.off.counts));
}

test "a whole block still spends its count and moves every unit" {
    var cells = Cells{};
    const memory = Memory{ .cells = &cells };
    var links = icu.Icu.init();
    var unit = scene(memory, &links, block_copy, 2, 0x10 << 8);
    memory.poke(source_at + 0x0F, 0x33);
    const moved = unit.activate(memory, &links, event).?;
    try std.testing.expectEqual(@as(u32, 0x10), moved.units);
    try std.testing.expectEqual(@as(u32, 0x10), moved.bytes);
    try std.testing.expectEqual(@as(u8, 0x33), memory.byteAt(dest_at + 0x0F));
    try std.testing.expectEqual(@as(u32, 1 | (0x10 << 24)), try memory.readWord(ti_at + xfer.off.counts));
}
