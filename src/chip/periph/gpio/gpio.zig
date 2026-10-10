//! GPIO / PORT: the pins every app on this board touches first.
//!
//! The RA8D2 puts PORT0..PORT14 at 0x4040_0000 on a 0x20 stride, and the FSP
//! ioport driver reaches them through the combined PCNTR registers rather than
//! the byte-wide aliases (HUM Ch 20.2 p 730-736, ra8_port_regs.h):
//!
//!   PCNTR1 = {PODR[31:16], PDR[15:0]}  RW  direction and output latch
//!   PCNTR2 = {EIDR[31:16], PIDR[15:0]}  R  live pin level
//!   PCNTR3 = {PORR[31:16], POSR[15:0]}  W  atomic clear / atomic set
//!   PCNTR4 = {EORR[31:16], EOSR[15:0]} RW  event output, unmodelled
//!
//! Until now these addresses fell through to the sparse register file, and
//! that file cannot be honest about a pin: PCNTR2 is a different register from
//! PCNTR1, so a firmware that drove a pin high and read the level back got the
//! alternating zero/ones stand-in instead of its own output, and a blink loop
//! that waits for its own LED could not be believed either way. A port is a
//! latch and a direction mask, which is small enough to model exactly, so this
//! models it exactly.
//!
//! PIDR here is the C tree's rule, ported from board_periph_gpio.c on dev: an
//! output pin reads back the latch it drives, an input pin reads whatever is
//! externally driven onto it, and anything else reads zero. The three EK-RA8D2
//! user LEDs live here too, as observability (level and edge count, reported
//! at the end of a run). Pins the board pulls high (the user switches,
//! src/board/switches.zig) are the board's to name through pullUp(); a pulled
//! pin reads high with nothing driving it.
const std = @import("std");
const periph = @import("../registry.zig");
const regs = @import("regs.zig");

/// Pin models (RA8EMU-497), reached through here because root.zig is full.
pub const pins = @import("pins.zig");

/// PORT geometry (HUM Ch 20.2 p 730). The Non-secure alias is folded onto this
/// base by the bus before anything here sees it.
pub const win_base: u32 = 0x4040_0000;
pub const port_stride: u32 = 0x20;
pub const port_count: u32 = 15;
pub const win_span: u32 = port_stride * port_count;

pub const pins_per_port: u32 = 16;

pub const pcntr1: u32 = regs.off.pcntr1;
pub const pcntr2: u32 = regs.off.pcntr2;
pub const pcntr3: u32 = regs.off.pcntr3;
pub const pcntr4: u32 = regs.off.pcntr4;

const half_shift: u5 = regs.half_shift;
const half_mask: u32 = regs.half_mask;

/// One PORT instance. Four 16-bit halves is the whole of it: what the firmware
/// drives, which way each pin faces, and which pins the board drives back.
const Port = struct {
    /// Direction, 1 = output.
    pdr: u16 = 0,
    /// Output-data latch.
    podr: u16 = 0,
    /// Pins whose input level comes from outside the firmware.
    in_ovr: u16 = 0,
    /// The level those pins are driven to.
    in_lvl: u16 = 0,

    /// What PIDR reads: driven outputs, plus externally-driven inputs.
    fn level(self: Port) u16 {
        const driven = self.podr & self.pdr;
        const inputs = ~self.pdr & self.in_ovr & self.in_lvl;
        return driven | inputs;
    }
};

/// A board LED: where it sits, and what colour it emits when driven high. The
/// colours are carried from the C tree so the board view can light them the
/// same way when the display slice lands.
const Led = struct {
    port: u8,
    pin: u4,
    rgb565: u16,
    name: []const u8,
};

pub const led_count: usize = 3;

pub const leds = [led_count]Led{
    .{ .port = 6, .pin = 0, .rgb565 = 0x001F, .name = "LED1 BLUE  P600" },
    .{ .port = 3, .pin = 3, .rgb565 = 0x07E0, .name = "LED2 GREEN P303" },
    .{ .port = 10, .pin = 7, .rgb565 = 0xF800, .name = "LED3 RED   PA07" },
};

pub const Gpio = struct {
    pub const EventOrigin = enum { firmware, external };
    /// A listener for a live port level changing.
    pub const EventTap = struct {
        context: *anyopaque,
        changedFn: *const fn (*anyopaque, u8, u16, u16, EventOrigin) void,
    };

    pub const Observer = struct {
        context: *anyopaque,
        changedFn: *const fn (*anyopaque, *Gpio, u8) void,
    };

    ports: [port_count]Port = @splat(.{}),
    /// Last level seen on each board LED, and how many times it changed.
    led_level: [led_count]u1 = @splat(0),
    led_edges: [led_count]u32 = @splat(0),
    /// Stores into PCNTR2, which the pads drive and firmware does not.
    refused: u32 = 0,
    observer: ?Observer = null,
    event_tap: ?EventTap = null,
    /// Device models wired to single pins with --attach.
    wired: pins.Pins = .{},
    /// Pins the board pulls high, per port. Wiring, set once by the board;
    /// reset and release fall back to it.
    pull_ups: [port_count]u16 = @splat(0),

    pub fn init() Gpio {
        var self = Gpio{};
        self.reset();
        return self;
    }

    /// Reset is not just zeroing: a pin the board pulls high has to read
    /// high, or a firmware poll of a released switch sees a press that never
    /// happened.
    pub fn reset(self: *Gpio) void {
        self.ports = @splat(.{});
        self.led_level = @splat(0);
        self.led_edges = @splat(0);
        self.refused = 0;
        for (&self.ports, self.pull_ups) |*port, high| {
            port.in_ovr = high;
            port.in_lvl = high;
        }
        self.wired.reconnect(self);
    }

    /// The board pulls `pin` high: it reads high whenever nothing drives it.
    pub fn pullUp(self: *Gpio, port: u8, pin: u4) void {
        if (port >= port_count) return;
        const bit = @as(u16, 1) << pin;
        self.pull_ups[port] |= bit;
        self.ports[port].in_ovr |= bit;
        self.ports[port].in_lvl |= bit;
    }

    /// Drive a pin from outside the firmware: a button press, or a peripheral
    /// that answers on a GPIO line (the e-paper HRDY in the C tree).
    pub fn observe(self: *Gpio, context: *anyopaque, changedFn: *const fn (*anyopaque, *Gpio, u8) void) void {
        self.observer = .{ .context = context, .changedFn = changedFn };
    }

    pub fn observeEvents(self: *Gpio, tap: EventTap) void {
        self.event_tap = tap;
    }

    fn notify(self: *Gpio, port: u8, before: u16, origin: EventOrigin) void {
        self.wired.portChanged(self, port);
        const levels = self.ports[port].level();
        if (self.event_tap) |tap| tap.changedFn(tap.context, port, levels, before ^ levels, origin);
        if (self.observer) |listener| listener.changedFn(listener.context, self, port);
    }

    pub fn setInput(self: *Gpio, port: u8, pin: u4, high: bool) void {
        if (port >= port_count) return;
        const before = self.ports[port].level();
        const bit = @as(u16, 1) << pin;
        self.ports[port].in_ovr |= bit;
        if (high) {
            self.ports[port].in_lvl |= bit;
        } else {
            self.ports[port].in_lvl &= ~bit;
        }
        if (self.ports[port].level() != before) self.notify(port, before, .external);
    }

    /// Stop driving a pin from outside (a part unplugged, RA8EMU-212): it
    /// falls back to its pull state. A pin the board pulls high reads high;
    /// this model has no pin pull register, so every other input reads low
    /// with nothing driving it.
    pub fn release(self: *Gpio, port: u8, pin: u4) void {
        if (port >= port_count) return;
        const before = self.ports[port].level();
        const bit = @as(u16, 1) << pin;
        self.ports[port].in_ovr &= ~bit;
        self.ports[port].in_lvl &= ~bit;
        if (self.pull_ups[port] & bit != 0) {
            self.ports[port].in_ovr |= bit;
            self.ports[port].in_lvl |= bit;
        }
        if (self.ports[port].level() != before) self.notify(port, before, .external);
    }

    pub fn getInput(self: *const Gpio, port: u8, pin: u4) bool {
        if (port >= port_count) return false;
        return (self.ports[port].in_lvl & (@as(u16, 1) << pin)) != 0;
    }

    /// The level a pin actually sits at, which is what PIDR answers.
    pub fn pinLevel(self: *const Gpio, port: u8, pin: u4) bool {
        if (port >= port_count) return false;
        return (self.ports[port].level() & (@as(u16, 1) << pin)) != 0;
    }

    pub fn portLevel(self: *const Gpio, port: u8) u16 {
        if (port >= port_count) return 0;
        return self.ports[port].level();
    }

    pub fn ledLevel(self: *const Gpio, index: usize) u1 {
        if (index >= led_count) return 0;
        return self.led_level[index];
    }

    pub fn ledEdges(self: *const Gpio, index: usize) u32 {
        if (index >= led_count) return 0;
        return self.led_edges[index];
    }

    /// How many stores the port refused, for the run report.
    pub fn refusedStores(self: *const Gpio) u32 {
        return self.refused;
    }

    pub fn quiet(self: *const Gpio) bool {
        for (self.led_edges) |edges| {
            if (edges != 0) return false;
        }
        return true;
    }

    /// Apply a new output latch and count any board-LED edge it caused. Every
    /// write path goes through here so PCNTR1 and PCNTR3 are counted alike.
    fn setLatch(self: *Gpio, index: u32, next: u16) void {
        const port = &self.ports[index];
        const before = port.podr;
        if (before == next) return;
        port.podr = next;
        for (leds, 0..) |led, i| {
            if (led.port != index) continue;
            const bit = @as(u16, 1) << led.pin;
            const was: u1 = if ((before & bit) != 0) 1 else 0;
            const now: u1 = if ((next & bit) != 0) 1 else 0;
            if (was == now) continue;
            self.led_level[i] = now;
            self.led_edges[i] += 1;
        }
    }

    /// A read of any width. The window is 32-bit registers spelled as pairs
    /// of 16-bit ones, so the word the access lands in answers it and the
    /// answer is then cut to the lanes the access names.
    pub fn readReg(self: *const Gpio, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        const index = offset / port_stride;
        if (index >= port_count) return 0;
        const local = offset % port_stride;
        return regs.part(self.wordValue(index, regs.word(local)), regs.lane(local), width);
    }

    /// What a whole PCNTR word reads as.
    fn wordValue(self: *const Gpio, index: u32, word: u32) u32 {
        const port = self.ports[index];
        return switch (word) {
            regs.off.pcntr1 => (@as(u32, port.podr) << half_shift) | @as(u32, port.pdr),
            regs.off.pcntr2 => @as(u32, port.level()),
            // PCNTR3 is write-only and PCNTR4's event output is unmodelled;
            // both read zero rather than borrowing the sparse file's toggle.
            else => 0,
        };
    }

    /// A store of any width, judged on the word it lands in and on the byte
    /// lanes it actually names. A halfword at +0x02 is PODR alone: it moves
    /// the latch and leaves the direction mask below it untouched.
    pub fn applyWrite(self: *Gpio, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        const index = offset / port_stride;
        if (index >= port_count) return;
        const local = offset % port_stride;
        const word = regs.word(local);
        const lane = regs.lane(local);
        if (regs.readOnly(word)) {
            self.refused += 1;
            return;
        }
        switch (word) {
            regs.off.pcntr1 => {
                const before = self.ports[index].level();
                const current = (@as(u32, self.ports[index].podr) << half_shift) |
                    @as(u32, self.ports[index].pdr);
                const next = regs.merge(current, lane, width, value);
                self.ports[index].pdr = @truncate(next & half_mask);
                self.setLatch(index, @truncate((next >> half_shift) & half_mask));
                self.notify(@intCast(index), before, .firmware);
            },
            regs.off.pcntr3 => {
                // POSR sets, PORR clears, in that order, so a word that names
                // the same pin in both halves leaves it clear the way the
                // hardware's clear-dominant pair does. The strobe does not
                // read back, so a narrow store names only its own half and
                // the other half is no set and no clear, not a stale value.
                const before = self.ports[index].level();
                const named = regs.merge(0, lane, width, value);
                const posr: u16 = @truncate(named & half_mask);
                const porr: u16 = @truncate((named >> half_shift) & half_mask);
                var latch = self.ports[index].podr;
                latch |= posr;
                latch &= ~porr;
                self.setLatch(index, latch);
                self.notify(@intCast(index), before, .firmware);
            },
            // PCNTR4 is the event output link: writable on silicon, not
            // modelled here, so the store is taken and forgotten rather than
            // refused.
            else => {},
        }
    }

    fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
        const self: *Gpio = @ptrCast(@alignCast(context));
        return self.readReg(address, width);
    }

    fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
        const self: *Gpio = @ptrCast(@alignCast(context));
        self.applyWrite(address, width, value);
    }

    pub fn block(self: *Gpio) periph.Block {
        return .{
            .name = "GPIO/PORT",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

/// The address of one PCNTR register, for tests and for anything that wants to
/// poke a port without doing the arithmetic itself.
pub fn regAddress(port: u32, offset: u32) u32 {
    return win_base + port * port_stride + offset;
}
