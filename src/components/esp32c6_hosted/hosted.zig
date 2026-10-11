//! The EK-RA8D2's SPI peer: the idle frame and sideband lines of esp-hosted.
const std = @import("std");
const sci = @import("ra8_chip").periph.sci;
const gpio = @import("ra8_chip").periph.gpio;

pub const frame = @import("frame.zig");
pub const event = @import("event.zig");
pub const link = @import("link.zig");
pub const rpc = @import("rpc.zig");
pub const station = @import("station.zig");
pub const queue = @import("queue.zig");
pub const eth = @import("eth.zig");
pub const dhcp = @import("dhcp.zig");
pub const gateway = @import("gateway.zig");
pub const scan = @import("scan.zig");
pub const dns = @import("dns.zig");
pub const net = @import("net.zig");
pub const tape = @import("tape/tape.zig");
pub const sock = @import("sock.zig");
pub const host_net = @import("host_net.zig");
pub const worker = @import("worker.zig");
pub const snapshot = @import("snapshot.zig");

pub const channel: usize = 2;
pub const handshake_port: u8 = 0;
pub const handshake_pin: u4 = 6;
pub const data_ready_port: u8 = 4;
pub const data_ready_pin: u4 = 2;
pub const chip_select_port: u8 = 8;
pub const chip_select_pin: u4 = 4;
pub const frame_size: u16 = 1600;
pub const idle_header: u8 = 0xF8;

/// The ESP32-C6 endpoint used by SCI2 and the Pmod1 sideband pins.
pub const C6 = struct {
    reply: [1]u8 = .{0},
    pins: ?*gpio.Gpio = null,
    wire: link.Link = .{},

    pub fn init(self: *C6, serial: *sci.Sci, pins: *gpio.Gpio) void {
        self.connect(pins);
        serial.attachDevice(channel, self.device());
    }

    pub fn connect(self: *C6, pins: *gpio.Gpio) void {
        self.pins = pins;
        pins.observe(self, pinChanged);
        pins.setInput(handshake_port, handshake_pin, true);
        pins.setInput(data_ready_port, data_ready_pin, false);
        pins.setInput(4, 12, true);
        pins.setInput(4, 13, true);
    }

    pub fn deinit(self: *C6) void {
        self.wire.deinit();
    }
    /// Hands the C6's DNS bridge the host Io it resolves names with.
    pub fn useIo(self: *C6, io: std.Io) void {
        self.wire.bridge.resolver.io = io;
    }
    /// Hands the C6's bridge the host network it opens sockets on
    /// (RA8EMU-1010), filled by the application from its socket layer.
    pub fn useNet(self: *C6, host: host_net.Net) void {
        self.wire.bridge.net = host;
    }
    /// Hands the C6's DNS bridge the background worker it resolves names
    /// on (RA8EMU-1020), filled by the application from its host threads.
    pub fn useWorker(self: *C6, background: worker.Worker) void {
        self.wire.bridge.worker = background;
    }
    /// Records or replays the C6's host traffic (RA8EMU-560).
    pub fn useTape(self: *C6, run: tape.Tape) void {
        self.wire.bridge.tape = run;
    }
    /// Replay requests that had no recording; a run with any must fail.
    pub fn tapeMisses(self: *const C6) u32 {
        return self.wire.bridge.tape.missed();
    }
    pub fn quiet(self: *const C6) bool {
        return !self.wire.networkActive();
    }

    pub fn device(self: *C6) sci.Device {
        return .{ .context = self, .feedFn = feed, .spi_only = true, .connectFn = connectDevice, .tickFn = tickDevice };
    }

    fn connectDevice(context: *anyopaque, pins: *gpio.Gpio) void {
        const self: *C6 = @ptrCast(@alignCast(context));
        self.connect(pins);
    }

    fn tickDevice(context: *anyopaque, pins: *gpio.Gpio) void {
        const self: *C6 = @ptrCast(@alignCast(context));
        self.tick(pins);
    }

    /// Polls host network traffic and refreshes the C6 sideband pins.
    pub fn tick(self: *C6, pins: *gpio.Gpio) void {
        self.wire.poll();
        self.updatePins(pins);
    }

    fn updatePins(self: *C6, pins: *gpio.Gpio) void {
        const direction = pins.readReg(gpio.regAddress(chip_select_port, gpio.pcntr1), 4);
        const selected = direction & (@as(u32, 1) << chip_select_pin) != 0;
        const handshake = !selected or pins.pinLevel(chip_select_port, chip_select_pin);
        pins.setInput(handshake_port, handshake_pin, handshake);
        pins.setInput(data_ready_port, data_ready_pin, self.wire.dataReady());
    }

    fn pinChanged(context: *anyopaque, pins: *gpio.Gpio, port: u8) void {
        if (port != chip_select_port) return;
        const self: *C6 = @ptrCast(@alignCast(context));
        self.updatePins(pins);
    }

    fn feed(context: *anyopaque, byte: u8) []const u8 {
        const self: *C6 = @ptrCast(@alignCast(context));
        self.reply[0] = self.wire.exchange(byte);
        if (self.pins) |pins| {
            pins.setInput(handshake_port, handshake_pin, false);
            pins.setInput(data_ready_port, data_ready_pin, self.wire.dataReady());
        }
        return &self.reply;
    }
};
