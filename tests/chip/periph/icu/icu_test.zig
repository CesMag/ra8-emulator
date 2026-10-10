//! The ICU event links: routing, the latch, the clear polarity, and the
//! re-pend that reproduces a handler which never took its flag down.
const std = @import("std");
const ra8 = @import("ra8");

const icu = ra8.chip.periph.icu;
const memmap = ra8.chip.core.memmap;

/// A stand-in for the core: the ICU only ever reaches the PPB, so a word map
/// is the whole of what it needs. Its two methods are called through `anytype`
/// from src/chip/periph/icu/icu.zig, so both are pub.
const FakeCore = struct {
    words: std.AutoHashMap(u32, u32),

    fn init(allocator: std.mem.Allocator) FakeCore {
        return .{ .words = std.AutoHashMap(u32, u32).init(allocator) };
    }

    fn deinit(self: *FakeCore) void {
        self.words.deinit();
    }

    pub fn readWord(self: *FakeCore, address: u32) !u32 {
        return self.words.get(address) orelse 0;
    }

    pub fn writeWord(self: *FakeCore, address: u32, value: u32) !void {
        try self.words.put(address, value);
    }
};

fn pendingBits(core: *FakeCore, word: u32) !u32 {
    return core.readWord(memmap.nvic.ispr + 4 * word);
}

test "an event pends the line whose IELSR listens for it" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    var unit = icu.Icu.init();

    unit.write(icu.slotAddress(35), 4, 0x123);
    try unit.raise(&core, 0x123);

    try std.testing.expect(unit.latched(35));
    try std.testing.expectEqual(@as(u32, 1) << 3, try pendingBits(&core, 1));
    try std.testing.expectEqual(@as(u64, 1), unit.raised);
    try std.testing.expectEqual(@as(u64, 1), unit.pends);
}

test "an event no slot links is counted and dropped" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    var unit = icu.Icu.init();

    unit.write(icu.slotAddress(35), 4, 0x123);
    try unit.raise(&core, 0x124);

    try std.testing.expectEqual(@as(u64, 1), unit.unlinked);
    try std.testing.expectEqual(@as(u64, 0), unit.pends);
    try std.testing.expectEqual(@as(u32, 0), try pendingBits(&core, 1));
}

test "IELS zero is no link, so event zero matches nothing" {
    var unit = icu.Icu.init();
    try std.testing.expectEqual(@as(?usize, null), unit.slotFor(0));
    unit.write(icu.slotAddress(7), 4, 0);
    try std.testing.expectEqual(@as(?usize, null), unit.slotFor(0));
}

test "the first slot listening for an event owns it" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    var unit = icu.Icu.init();

    unit.write(icu.slotAddress(9), 4, 0x122);
    unit.write(icu.slotAddress(40), 4, 0x122);
    try unit.raise(&core, 0x122);

    try std.testing.expect(unit.latched(9));
    try std.testing.expect(!unit.latched(40));
}

test "IR is write-zero-to-clear, so a written one leaves it standing" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    var unit = icu.Icu.init();

    unit.write(icu.slotAddress(2), 4, 0x123);
    try unit.raise(&core, 0x123);
    try std.testing.expect(unit.latched(2));

    // The move a driver makes when it thinks IR is write-one-to-clear.
    unit.write(icu.slotAddress(2), 4, 0x123 | icu.field.ir);
    try std.testing.expect(unit.latched(2));

    unit.write(icu.slotAddress(2), 4, 0x123);
    try std.testing.expect(!unit.latched(2));
}

test "a write keeps the link and the DTC enable, whatever IR does" {
    var unit = icu.Icu.init();
    unit.write(icu.slotAddress(11), 4, 0x080 | icu.field.dtce);
    const value = unit.read(icu.slotAddress(11), 4);
    try std.testing.expectEqual(@as(u32, 0x080), value & icu.field.iels);
    try std.testing.expect(value & icu.field.dtce != 0);
}

test "a still-latched line is pended again at the boundary" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    var unit = icu.Icu.init();

    unit.write(icu.slotAddress(1), 4, 0x123);
    try unit.raise(&core, 0x123);
    // Entry clears ISPR, the way src/chip/periph/nvic.zig does when it vectors in.
    try core.writeWord(memmap.nvic.ispr, 0);

    try unit.repend(&core);
    try std.testing.expectEqual(@as(u32, 1) << 1, try pendingBits(&core, 0));
    try std.testing.expectEqual(@as(u64, 1), unit.repends);
}

test "a handler that clears IR is not re-entered" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    var unit = icu.Icu.init();

    unit.write(icu.slotAddress(1), 4, 0x123);
    try unit.raise(&core, 0x123);
    try core.writeWord(memmap.nvic.ispr, 0);
    unit.write(icu.slotAddress(1), 4, 0x123);

    try unit.repend(&core);
    try std.testing.expectEqual(@as(u32, 0), try pendingBits(&core, 0));
    try std.testing.expectEqual(@as(u64, 0), unit.repends);
}

test "a line already pending is not pended twice" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    var unit = icu.Icu.init();

    unit.write(icu.slotAddress(1), 4, 0x123);
    try unit.raise(&core, 0x123);
    try unit.repend(&core);
    try std.testing.expectEqual(@as(u64, 0), unit.repends);
}

test "an event raised while IR is up latches nothing new" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    var unit = icu.Icu.init();

    unit.write(icu.slotAddress(5), 4, 0x123);
    try unit.raise(&core, 0x123);
    try unit.raise(&core, 0x123);

    try std.testing.expectEqual(@as(u64, 2), unit.raised);
    try std.testing.expectEqual(@as(u64, 1), unit.pends);
}

test "the pend is unconditional, so a line enabled later still takes it" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    var unit = icu.Icu.init();

    // Nothing has written ISER: dev would drop this pend and lose the event.
    unit.write(icu.slotAddress(64), 4, 0x122);
    try unit.raise(&core, 0x122);
    try std.testing.expectEqual(@as(u32, 1), try pendingBits(&core, 2));
}

test "an address outside the table answers nothing and changes nothing" {
    var unit = icu.Icu.init();
    unit.write(icu.win_base + icu.win_span, 4, 0x123);
    try std.testing.expectEqual(@as(u32, 0), unit.read(icu.win_base + icu.win_span, 4));
    try std.testing.expectEqual(@as(?usize, null), unit.slotFor(0x123));
    try std.testing.expect(unit.quiet());
}

test "slot n vectors through exception 16 + n" {
    try std.testing.expectEqual(@as(u16, 16), icu.exceptionFor(0));
    try std.testing.expectEqual(@as(u16, 51), icu.exceptionFor(35));
    try std.testing.expectEqual(icu.win_base + 4 * 35, icu.slotAddress(35));
}

test "a byte read of the flag lane answers IR, not the bottom of the event" {
    var unit = icu.Icu.init();
    unit.links[7] = 0x0000_0120 | icu.field.ir;

    const address = icu.slotAddress(7);
    try std.testing.expectEqual(@as(u32, 0x20), unit.read(address, 1));
    try std.testing.expectEqual(@as(u32, 0x01), unit.read(address + 1, 1));
    try std.testing.expectEqual(@as(u32, 0x01), unit.read(address + 2, 1));
    try std.testing.expectEqual(@as(u32, 0x00), unit.read(address + 3, 1));
}

test "a halfword read is cut to the half it names" {
    var unit = icu.Icu.init();
    unit.links[3] = 0x0000_0120 | icu.field.ir | icu.field.dtce;

    const address = icu.slotAddress(3);
    try std.testing.expectEqual(@as(u32, 0x0120), unit.read(address, 2));
    try std.testing.expectEqual(@as(u32, 0x0101), unit.read(address + 2, 2));
}

test "a byte store that takes IR down keeps the event number below it" {
    var unit = icu.Icu.init();
    unit.links[9] = 0x0000_0120 | icu.field.ir | icu.field.dtce;

    // The bitfield write a driver makes to acknowledge the interrupt.
    unit.write(icu.slotAddress(9) + 2, 1, 0x00);

    try std.testing.expectEqual(@as(u32, 0x120), unit.links[9] & icu.field.iels);
    try std.testing.expectEqual(@as(u32, 0), unit.links[9] & icu.field.ir);
    try std.testing.expect(unit.links[9] & icu.field.dtce != 0);
}

test "a byte store that does not name the flag lane leaves it latched" {
    var unit = icu.Icu.init();
    unit.links[4] = 0x0000_0033 | icu.field.ir;

    unit.write(icu.slotAddress(4), 1, 0x44);

    try std.testing.expectEqual(@as(u32, 0x44), unit.links[4] & icu.field.iels);
    try std.testing.expect(unit.links[4] & icu.field.ir != 0);
}

test "a byte store into the flag lane cannot raise a flag nothing latched" {
    var unit = icu.Icu.init();
    unit.links[5] = 0x0000_0012;

    unit.write(icu.slotAddress(5) + 2, 1, 0x01);

    try std.testing.expectEqual(@as(u32, 0), unit.links[5] & icu.field.ir);
    try std.testing.expectEqual(@as(u32, 0x12), unit.links[5] & icu.field.iels);
}

test "the top half of the event number survives a byte store to the low half" {
    var unit = icu.Icu.init();
    unit.links[11] = 0x0000_0120;

    unit.write(icu.slotAddress(11), 1, 0x21);

    try std.testing.expectEqual(@as(u32, 0x0121), unit.links[11] & icu.field.iels);
}

test "a lane the register does not occupy reads zero and stores nowhere" {
    var unit = icu.Icu.init();
    unit.links[2] = 0x0000_0044;

    // Byte 3 holds DTCE alone; the seven bits above it are reserved.
    unit.write(icu.slotAddress(2) + 3, 1, 0xFF);

    try std.testing.expectEqual(@as(u32, icu.field.dtce), unit.links[2] & ~icu.field.iels);
    try std.testing.expectEqual(@as(u32, 0x01), unit.read(icu.slotAddress(2) + 3, 1));
}

test "a word store still reaches every field at once" {
    var unit = icu.Icu.init();
    unit.links[1] = icu.field.ir;

    unit.write(icu.slotAddress(1), 4, 0x0000_0099 | icu.field.dtce);

    try std.testing.expectEqual(@as(u32, 0x99), unit.links[1] & icu.field.iels);
    try std.testing.expect(unit.links[1] & icu.field.dtce != 0);
    try std.testing.expectEqual(@as(u32, 0), unit.links[1] & icu.field.ir);
}

test "a halfword store into the low half leaves the flag and DTCE standing" {
    var unit = icu.Icu.init();
    unit.links[6] = 0x0000_0001 | icu.field.ir | icu.field.dtce;

    unit.write(icu.slotAddress(6), 2, 0x0155);

    try std.testing.expectEqual(@as(u32, 0x0155), unit.links[6] & icu.field.iels);
    try std.testing.expect(unit.links[6] & icu.field.ir != 0);
    try std.testing.expect(unit.links[6] & icu.field.dtce != 0);
}

test "an access outside the table is not served" {
    var unit = icu.Icu.init();
    unit.write(icu.win_base + icu.win_span, 1, 0xFF);
    try std.testing.expectEqual(@as(u32, 0), unit.read(icu.win_base + icu.win_span, 1));
    try std.testing.expectEqual(@as(u32, 0), unit.links[icu.slots - 1]);
}

test "the unit carries an INTSELR bank that starts with every event on CPU0" {
    var unit = icu.Icu.init();
    try std.testing.expectEqual(icu.intsel.Core.cpu0, unit.select.coreFor(7));
    const window = unit.select.block();
    try std.testing.expectEqual(icu.intsel.base, window.base);
    unit.select.write(icu.intsel.wordAddress(0), 4, 1 << 7);
    try std.testing.expectEqual(icu.intsel.Core.cpu1, unit.select.coreFor(7));
}

test "the bus window serves each core its own event-link table" {
    var unit = icu.Icu.init();
    var issuer: ra8.chip.periph.registry.Issuer = .cpu1;
    unit.issuer = &issuer;
    const window = unit.block();
    window.writeFn(window.context, icu.slotAddress(5), 4, 0x42);
    try std.testing.expectEqual(@as(u32, 0x42), unit.cpu1[5]);
    try std.testing.expectEqual(@as(u32, 0), unit.links[5]);
    try std.testing.expectEqual(@as(u32, 0x42), window.readFn(window.context, icu.slotAddress(5), 4));
    issuer = .cpu0;
    try std.testing.expectEqual(@as(u32, 0), window.readFn(window.context, icu.slotAddress(5), 4));
    window.writeFn(window.context, icu.slotAddress(5), 4, 0x17);
    try std.testing.expectEqual(@as(u32, 0x17), unit.links[5]);
    try std.testing.expectEqual(@as(u32, 0x42), unit.cpu1[5]);
}

test "a unit with no issuer keeps every access on ICU0" {
    var unit = icu.Icu.init();
    const window = unit.block();
    window.writeFn(window.context, icu.slotAddress(2), 4, 0x9);
    try std.testing.expectEqual(@as(u32, 0x9), unit.links[2]);
    try std.testing.expect(unit.tableFor(.cpu1)[2] == 0);
}

test "an event raised on ICU1 latches there and pends the core it is given" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    var unit = icu.Icu.init();
    unit.cpu1[4] = 0x55;
    try unit.raiseOn(.cpu1, &core, 0x55);
    try std.testing.expect(unit.cpu1[4] & icu.field.ir != 0);
    try std.testing.expect(!unit.latched(4));
    try std.testing.expectEqual(@as(u32, 1) << 4, try pendingBits(&core, 0));
    try core.writeWord(memmap.nvic.ispr, 0);
    try unit.rependOn(.cpu1, &core);
    try std.testing.expectEqual(@as(u32, 1) << 4, try pendingBits(&core, 0));
    unit.clearLatches();
    try std.testing.expect(unit.cpu1[4] & icu.field.ir == 0);
}

test "each core's DTCE bits are looked up in that core's own table" {
    var links = icu.Icu{};
    const event: u16 = 0x55;
    links.cpu1[3] = event | icu.field.dtce;
    links.links[7] = event;
    try std.testing.expectEqual(@as(?usize, 3), links.dtcSlotOn(.cpu1, event));
    try std.testing.expectEqual(@as(?usize, null), links.dtcSlotOn(.cpu0, event));
    try std.testing.expectEqual(@as(?usize, null), links.dtcSlotFor(event));
}

test "a descriptor running out takes DTCE down in its own core's table only" {
    var links = icu.Icu{};
    const event: u16 = 0x55;
    links.cpu1[3] = event | icu.field.dtce;
    links.links[3] = event | icu.field.dtce;
    links.clearDtceOn(.cpu1, 3);
    try std.testing.expectEqual(@as(u32, event), links.cpu1[3]);
    try std.testing.expectEqual(@as(u32, event | icu.field.dtce), links.links[3]);
}
