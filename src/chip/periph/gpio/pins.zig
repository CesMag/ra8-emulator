//! Device models wired to one GPIO pin each (RA8EMU-497).
//!
//! The port's one observer belongs to the ESP32-C6 link, so pin models do
//! not share it. A model gets a Link instead. Through it the model drives
//! its pin's input level, which the firmware reads back in PIDR, and every
//! store to the pin's port tells the model the level the pin now sits at.
const gpio = @import("gpio.zig");

/// As many pin models as a run can ask for with --attach.
pub const max_pins: usize = 4;

/// One pin, as a model sees it.
pub const Link = struct {
    pins: *gpio.Gpio,
    port: u8,
    pin: u4,

    /// Drive the pin's input level, as a button or a sensor line would.
    pub fn drive(self: Link, high: bool) void {
        self.pins.setInput(self.port, self.pin, high);
    }

    /// The level the pin sits at now.
    pub fn level(self: Link) bool {
        return self.pins.pinLevel(self.port, self.pin);
    }
};

/// What a pin model offers the port.
pub const Device = struct {
    context: *anyopaque,
    /// On attach and after every port reset, so a model drives its level
    /// again rather than losing it to the reset.
    connectFn: *const fn (*anyopaque, Link) void,
    /// The pin's level after a store to its port.
    heardFn: *const fn (*anyopaque, bool) void,
};

pub const Error = error{ PinTaken, PinsFull };

const Slot = struct { port: u8, pin: u4, device: Device };

/// The models wired to a port block's pins.
pub const Pins = struct {
    slots: [max_pins]Slot = undefined,
    count: usize = 0,

    /// Wire `device` to one pin. A pin carries one model.
    pub fn attach(self: *Pins, owner: *gpio.Gpio, port: u8, pin: u4, device: Device) Error!void {
        for (self.slots[0..self.count]) |slot| {
            if (slot.port == port and slot.pin == pin) return Error.PinTaken;
        }
        if (self.count == max_pins) return Error.PinsFull;
        self.slots[self.count] = .{ .port = port, .pin = pin, .device = device };
        self.count += 1;
        device.connectFn(device.context, .{ .pins = owner, .port = port, .pin = pin });
    }

    /// Hand every model its link again, after the port block reset.
    /// Take the part on `port`/`pin` off its pin; false when none was there.
    /// The caller lets the pin go back to its pull state.
    pub fn detach(self: *Pins, port: u8, pin: u4) bool {
        for (self.slots[0..self.count], 0..) |slot, index| {
            if (slot.port != port or slot.pin != pin) continue;
            self.count -= 1;
            self.slots[index] = self.slots[self.count];
            return true;
        }
        return false;
    }

    pub fn reconnect(self: *const Pins, owner: *gpio.Gpio) void {
        for (self.slots[0..self.count]) |slot| {
            const link = Link{ .pins = owner, .port = slot.port, .pin = slot.pin };
            slot.device.connectFn(slot.device.context, link);
        }
    }

    /// Tell the models on `port` what level their pin sits at.
    pub fn portChanged(self: *const Pins, owner: *const gpio.Gpio, port: u8) void {
        for (self.slots[0..self.count]) |slot| {
            if (slot.port != port) continue;
            slot.device.heardFn(slot.device.context, owner.pinLevel(port, slot.pin));
        }
    }
};
