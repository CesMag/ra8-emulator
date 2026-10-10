//! Covers src/chip/periph/icu/irqcr.zig and the ICU's IRQCRa/IRQCRb window: the
//! two-run address arithmetic, the field mask, and the rule that a pin may
//! only be rewritten while nothing routes its event.
const std = @import("std");
const ra8 = @import("ra8");

const icu = ra8.chip.periph.icu;
const irqcr = ra8.chip.periph.icu_irqcr;

const base = icu.icu_base;

fn unit() icu.Icu {
    return icu.Icu.init();
}

/// Route `channel`'s event to a line, the way ra8_isr_register does.
fn route(self: *icu.Icu, slot: usize, channel: usize) void {
    self.write(icu.slotAddress(slot), 4, irqcr.eventFor(channel));
}

test "the two runs sit where the offset table puts them" {
    try std.testing.expectEqual(@as(u32, base + 0x0000), irqcr.pinAddress(base, 0));
    try std.testing.expectEqual(@as(u32, base + 0x000F), irqcr.pinAddress(base, 15));
    try std.testing.expectEqual(@as(u32, base + 0x0014), irqcr.pinAddress(base, 16));
    try std.testing.expectEqual(@as(u32, base + 0x0023), irqcr.pinAddress(base, 31));
}

test "the four bytes between the runs belong to no channel" {
    try std.testing.expectEqual(@as(?usize, 15), irqcr.channelAt(0x0F));
    try std.testing.expectEqual(@as(?usize, null), irqcr.channelAt(0x10));
    try std.testing.expectEqual(@as(?usize, null), irqcr.channelAt(0x13));
    try std.testing.expectEqual(@as(?usize, 16), irqcr.channelAt(0x14));
}

test "a channel's event is its number plus one" {
    try std.testing.expectEqual(@as(u16, 0x001), irqcr.eventFor(0));
    try std.testing.expectEqual(@as(u16, 0x00D), irqcr.eventFor(12));
    try std.testing.expectEqual(@as(u16, 0x010), irqcr.eventFor(15));
}

test "a pin configured before anything is routed reads back and is quiet" {
    var self = unit();
    self.pins.store(irqcr.pinAddress(0, 3), irqcr.field.flten | 0x01, self.pinRouted(3));
    try std.testing.expectEqual(
        @as(u8, irqcr.field.flten | 0x01),
        self.pins.read(irqcr.pinAddress(0, 3)),
    );
    try std.testing.expectEqual(@as(u32, 0), self.pins.rewrites_while_routed);
}

test "the reserved bits of a pin do not stick" {
    var self = unit();
    self.pins.store(irqcr.pinAddress(0, 1), 0xFF, false);
    try std.testing.expectEqual(@as(u8, irqcr.field.occupied), self.pins.read(irqcr.pinAddress(0, 1)));
}

test "a store into the gap between the runs lands nowhere" {
    var self = unit();
    self.pins.store(0x10, 0xFF, false);
    try std.testing.expectEqual(@as(u8, 0), self.pins.read(0x10));
    try std.testing.expect(self.pins.quiet());
}

test "rewriting a pin while its event is routed is counted" {
    var self = unit();
    self.pins.store(irqcr.pinAddress(0, 5), 0x01, self.pinRouted(5));
    route(&self, 7, 5);
    try std.testing.expect(self.pinRouted(5));
    self.pins.store(irqcr.pinAddress(0, 5), 0x02, self.pinRouted(5));
    try std.testing.expectEqual(@as(u32, 1), self.pins.rewrites_while_routed);
    // The store still lands: nothing written down says the part drops it.
    try std.testing.expectEqual(@as(u8, 0x02), self.pins.read(irqcr.pinAddress(0, 5)));
}

test "storing the value already there is not a rewrite" {
    var self = unit();
    self.pins.store(irqcr.pinAddress(0, 5), 0x02, false);
    route(&self, 7, 5);
    self.pins.store(irqcr.pinAddress(0, 5), 0x02, self.pinRouted(5));
    try std.testing.expectEqual(@as(u32, 0), self.pins.rewrites_while_routed);
}

test "unrouting the event first is the sequence the warning asks for" {
    var self = unit();
    route(&self, 7, 9);
    self.write(icu.slotAddress(7), 4, 0);
    try std.testing.expect(!self.pinRouted(9));
    self.pins.store(irqcr.pinAddress(0, 9), 0x03, self.pinRouted(9));
    try std.testing.expectEqual(@as(u32, 0), self.pins.rewrites_while_routed);
}

test "a routed event on one channel does not gag its neighbour" {
    var self = unit();
    route(&self, 4, 20);
    self.pins.store(irqcr.pinAddress(0, 21), 0x01, self.pinRouted(21));
    try std.testing.expectEqual(@as(u32, 0), self.pins.rewrites_while_routed);
    self.pins.store(irqcr.pinAddress(0, 20), 0x01, self.pinRouted(20));
    try std.testing.expectEqual(@as(u32, 1), self.pins.rewrites_while_routed);
}

test "the window reads and writes through the block the ICU builds" {
    var self = unit();
    const b = self.pinsBlock();
    try std.testing.expectEqual(base, b.base);
    try std.testing.expectEqual(irqcr.win_span, b.size);
    b.writeFn(b.context, irqcr.pinAddress(base, 16), 1, 0x30);
    try std.testing.expectEqual(
        @as(u32, 0x30),
        b.readFn(b.context, irqcr.pinAddress(base, 16), 1),
    );
}

test "a word store at the top of the window reaches four pins at once" {
    var self = unit();
    const b = self.pinsBlock();
    route(&self, 2, 1);
    b.writeFn(b.context, base, 4, 0x03_02_01_03);
    try std.testing.expectEqual(@as(u8, 0x03), self.pins.read(0));
    try std.testing.expectEqual(@as(u8, 0x01), self.pins.read(1));
    try std.testing.expectEqual(@as(u8, 0x02), self.pins.read(2));
    try std.testing.expectEqual(@as(u8, 0x03), self.pins.read(3));
    // Only channel 1's event was routed, so only that lane is counted.
    try std.testing.expectEqual(@as(u32, 1), self.pins.rewrites_while_routed);
}

test "configured counts the pins a run actually programmed" {
    var self = unit();
    try std.testing.expectEqual(@as(usize, 0), self.pins.configured());
    self.pins.store(irqcr.pinAddress(0, 0), 0x01, false);
    self.pins.store(irqcr.pinAddress(0, 31), 0x80, false);
    try std.testing.expectEqual(@as(usize, 2), self.pins.configured());
    try std.testing.expect(!self.pins.quiet());
}

test {
    _ = @import("pin_irq_test.zig");
}
