//! Tests for src/chip/periph/gpio/gpio.zig.
const std = @import("std");
const ra8 = @import("ra8");
const periph = ra8.chip.periph.registry;
const mod = ra8.chip.periph.gpio;
const regs = ra8.chip.periph.gpio_regs;

const Gpio = mod.Gpio;
const pcntr1 = mod.pcntr1;
const pcntr2 = mod.pcntr2;
const pcntr3 = mod.pcntr3;
const pcntr4 = mod.pcntr4;
const regAddress = mod.regAddress;
/// The EK-RA8D2 switch pins (SW1 = P009, SW2 = P008), which the board pulls
/// high; the chip model knows them only through pullUp.
const sw_port: u8 = 0;
const sw1_pin: u4 = 9;
const sw2_pin: u4 = 8;
const win_base = mod.win_base;
const win_span = mod.win_span;

/// A port block wired as the board wires it: both switch pins pulled high.
fn pulled() Gpio {
    var gpio = Gpio.init();
    gpio.pullUp(sw_port, sw1_pin);
    gpio.pullUp(sw_port, sw2_pin);
    return gpio;
}

test "a bare port block pulls nothing up; a pulled pin survives reset and release" {
    var gpio = Gpio.init();
    try std.testing.expect(!gpio.pinLevel(sw_port, sw1_pin));
    gpio.pullUp(sw_port, sw1_pin);
    try std.testing.expect(gpio.pinLevel(sw_port, sw1_pin));
    gpio.setInput(sw_port, sw1_pin, false);
    gpio.release(sw_port, sw1_pin);
    try std.testing.expect(gpio.pinLevel(sw_port, sw1_pin));
    gpio.reset();
    try std.testing.expect(gpio.pinLevel(sw_port, sw1_pin));
    try std.testing.expect(!gpio.pinLevel(sw_port, sw2_pin));
}

test "a port resets with nothing driven and both switches released" {
    const gpio = pulled();
    try std.testing.expectEqual(@as(u32, 0), gpio.readReg(regAddress(6, pcntr1), 4));
    try std.testing.expect(gpio.pinLevel(sw_port, sw1_pin));
    try std.testing.expect(gpio.pinLevel(sw_port, sw2_pin));
    try std.testing.expectEqual(@as(u1, 0), gpio.ledLevel(0));
}

test "PCNTR1 carries the latch in the high half and the direction in the low" {
    var gpio = pulled();
    gpio.applyWrite(regAddress(6, pcntr1), 4, (@as(u32, 0x0001) << 16) | 0x0001);
    try std.testing.expectEqual(@as(u32, 0x0001_0001), gpio.readReg(regAddress(6, pcntr1), 4));
    try std.testing.expectEqual(@as(u16, 1), gpio.ports[6].pdr);
    try std.testing.expectEqual(@as(u16, 1), gpio.ports[6].podr);
}

test "an output pin reads its own level back through PCNTR2" {
    var gpio = pulled();
    // P600 as an output, driven high: this is the LED1 blink the sparse file
    // could never answer honestly.
    gpio.applyWrite(regAddress(6, pcntr1), 4, (@as(u32, 1) << 16) | 1);
    try std.testing.expectEqual(@as(u32, 1), gpio.readReg(regAddress(6, pcntr2), 4));
    gpio.applyWrite(regAddress(6, pcntr1), 4, (@as(u32, 0) << 16) | 1);
    try std.testing.expectEqual(@as(u32, 0), gpio.readReg(regAddress(6, pcntr2), 4));
}

test "an input pin reads what the board drives, not what the latch holds" {
    var gpio = pulled();
    // Latch high but direction input: the pin is not driven by the firmware.
    gpio.applyWrite(regAddress(0, pcntr1), 4, (@as(u32, 1) << 16) | 0);
    try std.testing.expectEqual(@as(u32, 0), gpio.readReg(regAddress(0, pcntr2), 4) & 1);
    gpio.setInput(0, 0, true);
    try std.testing.expectEqual(@as(u32, 1), gpio.readReg(regAddress(0, pcntr2), 4) & 1);
}

test "pressing a user switch pulls its pin low" {
    var gpio = pulled();
    const sw1 = @as(u32, 1) << sw1_pin;
    try std.testing.expectEqual(sw1, gpio.readReg(regAddress(sw_port, pcntr2), 4) & sw1);
    gpio.setInput(sw_port, sw1_pin, false);
    try std.testing.expectEqual(@as(u32, 0), gpio.readReg(regAddress(sw_port, pcntr2), 4) & sw1);
    try std.testing.expect(!gpio.getInput(sw_port, sw1_pin));
}

test "PCNTR3 sets and clears without touching the rest of the port" {
    var gpio = pulled();
    gpio.applyWrite(regAddress(3, pcntr1), 4, (@as(u32, 0x00F0) << 16) | 0xFFFF);
    gpio.applyWrite(regAddress(3, pcntr3), 4, 0x0003); // POSR: set pins 0,1
    try std.testing.expectEqual(@as(u16, 0x00F3), gpio.ports[3].podr);
    gpio.applyWrite(regAddress(3, pcntr3), 4, @as(u32, 0x00F0) << 16); // PORR
    try std.testing.expectEqual(@as(u16, 0x0003), gpio.ports[3].podr);
    try std.testing.expectEqual(@as(u16, 0xFFFF), gpio.ports[3].pdr);
}

test "a pin named in both PCNTR3 halves ends clear" {
    var gpio = pulled();
    gpio.applyWrite(regAddress(1, pcntr3), 4, (@as(u32, 0x0001) << 16) | 0x0001);
    try std.testing.expectEqual(@as(u16, 0), gpio.ports[1].podr);
}

test "PCNTR3 reads zero, and PCNTR4 is unmodelled" {
    var gpio = pulled();
    gpio.applyWrite(regAddress(2, pcntr3), 4, 0xFFFF);
    try std.testing.expectEqual(@as(u32, 0), gpio.readReg(regAddress(2, pcntr3), 4));
    gpio.applyWrite(regAddress(2, pcntr4), 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), gpio.readReg(regAddress(2, pcntr4), 4));
}

test "a blink counts one edge per change, on either write path" {
    var gpio = pulled();
    gpio.applyWrite(regAddress(6, pcntr1), 4, 1); // P600 output, latch low
    try std.testing.expect(gpio.quiet());
    gpio.applyWrite(regAddress(6, pcntr3), 4, 1); // POSR high
    gpio.applyWrite(regAddress(6, pcntr3), 4, @as(u32, 1) << 16); // PORR low
    gpio.applyWrite(regAddress(6, pcntr1), 4, (@as(u32, 1) << 16) | 1); // high again
    try std.testing.expectEqual(@as(u32, 3), gpio.ledEdges(0));
    try std.testing.expectEqual(@as(u1, 1), gpio.ledLevel(0));
    try std.testing.expect(!gpio.quiet());
}

test "writing the same latch twice is not an edge" {
    var gpio = pulled();
    gpio.applyWrite(regAddress(3, pcntr1), 4, (@as(u32, 1) << (16 + 3)) | (1 << 3));
    gpio.applyWrite(regAddress(3, pcntr1), 4, (@as(u32, 1) << (16 + 3)) | (1 << 3));
    try std.testing.expectEqual(@as(u32, 1), gpio.ledEdges(1));
}

test "each LED tracks only its own port and pin" {
    var gpio = pulled();
    gpio.applyWrite(regAddress(10, pcntr1), 4, (@as(u32, 0xFFFF) << 16) | 0xFFFF);
    try std.testing.expectEqual(@as(u32, 1), gpio.ledEdges(2));
    try std.testing.expectEqual(@as(u32, 0), gpio.ledEdges(0));
    try std.testing.expectEqual(@as(u32, 0), gpio.ledEdges(1));
}

test "the window ends at PORT14 and addresses past it are inert" {
    var gpio = pulled();
    try std.testing.expectEqual(win_base + 0x1E0, win_base + win_span);
    gpio.applyWrite(win_base + win_span, 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), gpio.readReg(win_base + win_span, 4));
}

test "the port block answers on the bus, on both security aliases" {
    var bus = periph.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var gpio = pulled();
    try bus.add(gpio.block());

    bus.write(regAddress(6, pcntr1), 4, (@as(u32, 1) << 16) | 1);
    try std.testing.expectEqual(@as(u32, 1), bus.read(periph.ns_base - periph.base + regAddress(6, pcntr2), 4));
    try std.testing.expectEqual(@as(u32, 0), bus.unmodelledAddresses());
}

test "a halfword store to PODR drives the latch and leaves PDR alone" {
    var gpio = pulled();
    gpio.applyWrite(regAddress(6, pcntr1), 4, 0x0000_FFFF);
    gpio.applyWrite(regAddress(6, regs.off.podr), 2, 0x0001);
    try std.testing.expectEqual(@as(u32, 0x0001_FFFF), gpio.readReg(regAddress(6, pcntr1), 4));
    try std.testing.expectEqual(@as(u1, 1), gpio.ledLevel(0));
}

test "a halfword read of PODR answers the latch, not zero" {
    var gpio = pulled();
    gpio.applyWrite(regAddress(3, pcntr1), 4, (@as(u32, 0xBEEF) << 16) | 0xFFFF);
    try std.testing.expectEqual(@as(u32, 0xBEEF), gpio.readReg(regAddress(3, regs.off.podr), 2));
    try std.testing.expectEqual(@as(u32, 0xFFFF), gpio.readReg(regAddress(3, regs.off.pdr), 2));
}

test "a halfword store to PDR leaves the latch above it alone" {
    var gpio = pulled();
    gpio.applyWrite(regAddress(6, pcntr1), 4, (@as(u32, 0x0001) << 16) | 0x0001);
    gpio.applyWrite(regAddress(6, regs.off.pdr), 2, 0x00FF);
    try std.testing.expectEqual(@as(u32, 0x0001_00FF), gpio.readReg(regAddress(6, pcntr1), 4));
    try std.testing.expectEqual(@as(u32, 1), gpio.ledEdges(0));
}

test "a byte store names one lane of the latch" {
    var gpio = pulled();
    gpio.applyWrite(regAddress(10, pcntr1), 4, 0x0000_FFFF);
    gpio.applyWrite(regAddress(10, regs.off.podr + 1), 1, 0xFF);
    try std.testing.expectEqual(@as(u32, 0xFF00_FFFF), gpio.readReg(regAddress(10, pcntr1), 4));
}

test "a halfword read of PIDR answers the live level" {
    var gpio = pulled();
    try std.testing.expectEqual(
        @as(u32, (@as(u32, 1) << sw1_pin) | (@as(u32, 1) << sw2_pin)),
        gpio.readReg(regAddress(sw_port, regs.off.pidr), 2),
    );
}

test "a store into PCNTR2 is refused, at any width and either half" {
    var gpio = pulled();
    gpio.applyWrite(regAddress(6, pcntr2), 4, 0xFFFF_FFFF);
    gpio.applyWrite(regAddress(6, regs.off.eidr), 2, 0xFFFF);
    gpio.applyWrite(regAddress(6, regs.off.pidr), 1, 0xFF);
    try std.testing.expectEqual(@as(u32, 3), gpio.refusedStores());
    try std.testing.expectEqual(@as(u32, 0), gpio.readReg(regAddress(6, pcntr2), 4));
}

test "a halfword store to PORR clears without the other half clearing everything" {
    var gpio = pulled();
    gpio.applyWrite(regAddress(6, pcntr1), 4, (@as(u32, 0x0003) << 16) | 0x0003);
    gpio.applyWrite(regAddress(6, regs.off.porr), 2, 0x0001);
    try std.testing.expectEqual(@as(u32, 0x0002_0003), gpio.readReg(regAddress(6, pcntr1), 4));
}

test "a halfword store to POSR sets without clearing" {
    var gpio = pulled();
    gpio.applyWrite(regAddress(6, pcntr1), 4, (@as(u32, 0x0002) << 16) | 0x0003);
    gpio.applyWrite(regAddress(6, regs.off.posr), 2, 0x0001);
    try std.testing.expectEqual(@as(u32, 0x0003_0003), gpio.readReg(regAddress(6, pcntr1), 4));
}

test "a store into PCNTR4 is taken and forgotten, not refused" {
    var gpio = pulled();
    gpio.applyWrite(regAddress(6, pcntr4), 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), gpio.refusedStores());
    try std.testing.expectEqual(@as(u32, 0), gpio.readReg(regAddress(6, pcntr4), 4));
}

const Observe = struct {
    count: u32 = 0,
    port: u8 = 0,

    fn changed(context: *anyopaque, gpio: *Gpio, port: u8) void {
        _ = gpio;
        const self: *Observe = @ptrCast(@alignCast(context));
        self.count += 1;
        self.port = port;
    }
};

test "port output changes notify a wired device" {
    var gpio = pulled();
    var observed = Observe{};
    gpio.observe(&observed, Observe.changed);
    gpio.applyWrite(regAddress(8, pcntr1), 4, (@as(u32, 1) << 20) | 0x10);
    try std.testing.expectEqual(@as(u32, 1), observed.count);
    try std.testing.expectEqual(@as(u8, 8), observed.port);
    gpio.applyWrite(regAddress(8, pcntr3), 4, 0x10);
    try std.testing.expectEqual(@as(u32, 2), observed.count);
}
