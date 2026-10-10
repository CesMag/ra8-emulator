//! Host switch edges reaching the ICU (RA8EMU-375): PFS ISEL gates the pin,
//! IRQCR.IRQMD picks the direction, and a passing edge pends its line.
const std = @import("std");
const ra8 = @import("ra8");

const icu = ra8.chip.periph.icu;
const pin_irq = icu.pin_irq;
const pfs = ra8.chip.periph.pfs;
const gpio = ra8.chip.periph.gpio;
const gt911 = ra8.components.gt911;
const switches = ra8.board.switches;
const sw1 = switches.user[0];
const memmap = ra8.chip.core.memmap;

/// The ICU only reaches the NVIC pending words, so a word map is enough.
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

const Rig = struct {
    input: gt911.host.Input = .{ .switches = &switches.user },
    panel: gt911.Panel = .{},
    pins: gpio.Gpio = switches.pulled(),
    pinfunc: pfs.Pfs = pfs.Pfs.init(),
    events: icu.Icu = icu.Icu.init(),

    /// Mark SW1's pin as an IRQ input, or not.
    fn sw1Isel(self: *Rig, on: bool) void {
        const at = pfs.Pfs.indexOf(sw1.port, sw1.pin);
        self.pinfunc.entries[at] = if (on) pin_irq.isel else 0;
    }

    /// Offer every queued edge the way the board boundary does.
    fn boundary(self: *Rig, core: *FakeCore) !void {
        for (self.input.edges.take()) |edge| {
            if (pin_irq.fires(&self.pinfunc, &self.events.pins, edge)) try self.events.raise(core, pin_irq.eventOf(edge));
        }
    }
};

const slot: usize = 40;

fn pended(core: *FakeCore) !bool {
    const word = try core.readWord(memmap.nvic.ispr + 4 * (slot / 32));
    return word & (@as(u32, 1) << @intCast(slot % 32)) != 0;
}

fn armSw1(rig: *Rig, mode: u8) void {
    rig.events.pins.pins[13] = mode;
    rig.events.write(icu.slotAddress(slot), 4, pin_irq.eventOf(.{ .channel = 13, .port = 0, .pin = 9, .falling = true }));
}

test "sw1 press with ISEL set and falling-edge sense pends IRQ13's line" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    var rig = Rig{};
    armSw1(&rig, pin_irq.sense.falling);
    rig.sw1Isel(true);

    rig.input.feedLine(&rig.panel, &rig.pins, "sw1 down");
    try rig.boundary(&core);
    try std.testing.expect(try pended(&core));
    try std.testing.expect(rig.events.latched(slot));
}

test "a release under falling-edge sense pends nothing" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    var rig = Rig{};
    rig.input.feedLine(&rig.panel, &rig.pins, "sw1 down");
    _ = rig.input.edges.take();
    armSw1(&rig, pin_irq.sense.falling);
    rig.sw1Isel(true);

    rig.input.feedLine(&rig.panel, &rig.pins, "sw1 up");
    try rig.boundary(&core);
    try std.testing.expect(!try pended(&core));
}

test "with ISEL clear a press pends nothing" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    var rig = Rig{};
    armSw1(&rig, pin_irq.sense.falling);
    rig.sw1Isel(false);

    rig.input.feedLine(&rig.panel, &rig.pins, "sw1 down");
    try rig.boundary(&core);
    try std.testing.expect(!try pended(&core));
}

test "only a real level change queues an edge" {
    var rig = Rig{};
    rig.input.feedLine(&rig.panel, &rig.pins, "sw1 up");
    try std.testing.expectEqual(@as(usize, 0), rig.input.edges.take().len);
    rig.input.feedLine(&rig.panel, &rig.pins, "sw2 down");
    rig.input.feedLine(&rig.panel, &rig.pins, "sw2 down");
    const edges = rig.input.edges.take();
    try std.testing.expectEqual(@as(usize, 1), edges.len);
    try std.testing.expectEqual(@as(u8, 12), edges[0].channel);
    try std.testing.expect(edges[0].falling);
}

test "IRQMD picks the direction" {
    try std.testing.expect(pin_irq.senses(pin_irq.sense.falling, true));
    try std.testing.expect(!pin_irq.senses(pin_irq.sense.falling, false));
    try std.testing.expect(pin_irq.senses(pin_irq.sense.rising, false));
    try std.testing.expect(!pin_irq.senses(pin_irq.sense.rising, true));
    try std.testing.expect(pin_irq.senses(pin_irq.sense.both, true));
    try std.testing.expect(pin_irq.senses(pin_irq.sense.both, false));
    try std.testing.expect(pin_irq.senses(pin_irq.sense.low, true));
    try std.testing.expect(!pin_irq.senses(pin_irq.sense.low, false));
}

test "a full queue drops and counts" {
    var queue = pin_irq.Queue{};
    for (0..pin_irq.capacity + 2) |_| queue.push(.{ .channel = 13, .port = 0, .pin = 9, .falling = true });
    try std.testing.expectEqual(@as(u32, 2), queue.dropped);
    try std.testing.expectEqual(pin_irq.capacity, queue.take().len);
    try std.testing.expectEqual(@as(usize, 0), queue.take().len);
}
