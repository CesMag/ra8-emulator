//! Where a catalog model's device goes on this board, and the run's
//! `--attach` asks waiting to be plugged.
//!
//! The endpoint names the line; this file names the block behind it. I2C
//! goes to the Wire (the RIIC line or the touch line). SPI goes to an SPI_B
//! channel and UART to an SCI channel. Those two channel models carry one
//! device per channel, so a channel that already has something on it is
//! refused rather than replaced: SPI0 holds the e-ink panel, SCI0 the
//! microSD line and SCI7 the modem. The SPI select is kept on the endpoint,
//! but the channel has no per-select routing yet, so it does not change
//! which device answers. GPIO goes to the port block's pin table, one model
//! per pin.
const std = @import("std");
const catalog = @import("ra8_components").catalog;
const endpoint = @import("ra8_components").endpoint;
const parts = @import("ra8_components").parts;
const request = @import("ra8_components").request;
const profile = @import("profile.zig");
const fault_spec = @import("ra8_components").fault.spec;
const eink = @import("ra8_components").eink;
const Board = @import("board.zig").Board;

pub const Error = error{ ChannelTaken, NothingFitted };

/// The `--attach` asks, kept from before the board is wired until wiring
/// plugs them after the fitted parts. Instances come from `arena`.
pub const Asks = struct {
    asked: [request.max + profile.max_fits]request.Request = undefined,
    count: usize = 0,
    arena: ?std.mem.Allocator = null,
    attached_eink: ?*eink.Panel = null,

    /// `asks` is at most `request.max` long, as the command line allows.
    pub fn keep(self: *Asks, arena: std.mem.Allocator, asks: []const request.Request) void {
        @memcpy(self.asked[0..asks.len], asks);
        self.count = asks.len;
        self.arena = arena;
    }
};

/// Make and plug every kept ask. A clash prints which ask caused it.
pub fn all(board: *Board) !void {
    const arena = board.asks.arena orelse return;
    for (board.asks.asked[0..board.asks.count]) |wanted| {
        if (wanted.name.len == 0) {
            fitted(board, arena, wanted) catch |err| {
                std.debug.print("--fault on a fitted part: not applied ({s})\n", .{@errorName(err)});
                return err;
            };
            continue;
        }
        const made = if (std.mem.eql(u8, wanted.name, parts.c6_name)) blk: {
            if (wanted.at != .uart or wanted.at.uart.channel != 2) return catalog.Error.WrongEndpoint;
            break :blk catalog.Instance{ .model = parts.all.find(parts.c6_name).?, .device = try parts.all.bind(parts.c6_name, &board.c6, wanted.at), .state = &board.c6 };
        } else try parts.all.make(arena, wanted.name, wanted.at);
        const device = faulted(board, arena, made.device, wanted) catch |err| {
            std.debug.print("--fault {s}: not applied ({s})\n", .{ wanted.name, @errorName(err) });
            return err;
        };
        one(board, device, wanted.at) catch |err| {
            std.debug.print("--attach {s}: nothing put on the line ({s})\n", .{ wanted.name, @errorName(err) });
            return err;
        };
        if (std.mem.eql(u8, wanted.name, parts.panel_name)) {
            const panel: *eink.Panel = @ptrCast(@alignCast(made.state));
            if (wanted.geometry) |geometry| panel.planes.resize(geometry);
            board.asks.attached_eink = panel;
        }
    }
}

/// The device as `--fault` asked it to misbehave, timed on the run's clock.
/// bus_low leaves the part alone and holds its I2C line low instead.
fn faulted(board: *Board, arena: std.mem.Allocator, device: catalog.Device, wanted: request.Request) !catalog.Device {
    const mode = wanted.fault orelse return device;
    const out = try fault_spec.apply(arena, device, mode, &board.time.base);
    if (mode == .bus_low) {
        if (wanted.at != .i2c) return catalog.Error.WrongEndpoint;
        switch (wanted.at.i2c.line) {
            .riic => board.wire.controller.devices.hold(true),
            .touch => board.wire.touchline.devices.hold(true),
        }
    }
    return out;
}

/// `--fault @ENDPOINT=MODE`: the part the board fitted at that I2C address
/// is wrapped where it sits in its line's registry (RA8EMU-536).
pub fn fitted(board: *Board, arena: std.mem.Allocator, wanted: request.Request) !void {
    if (wanted.at != .i2c) return catalog.Error.WrongEndpoint;
    const mode = wanted.fault orelse return;
    const registry = switch (wanted.at.i2c.line) {
        .riic => &board.wire.controller.devices,
        .touch => &board.wire.touchline.devices,
    };
    const found = registry.find(wanted.at.i2c.address) orelse return Error.NothingFitted;
    const out = try fault_spec.apply(arena, .{ .i2c = found.* }, mode, &board.time.base);
    if (mode == .bus_low) return registry.hold(true);
    found.* = out.i2c;
}

/// Put one device on the line its endpoint names.
pub fn one(board: *Board, device: catalog.Device, at: endpoint.Endpoint) !void {
    switch (device) {
        .i2c => try board.wire.plug(device, at),
        .spi => |part| {
            if (at != .spi) return catalog.Error.WrongEndpoint;
            const unit = &board.spi.channels[at.spi.channel];
            if (unit.device != null) return Error.ChannelTaken;
            board.spi.attachDevice(at.spi.channel, part);
        },
        .uart => |part| {
            if (at != .uart) return catalog.Error.WrongEndpoint;
            const unit = &board.serial.channels[at.uart.channel];
            if (unit.device != null) return Error.ChannelTaken;
            part.connect(&board.pins);
            board.serial.attachDevice(at.uart.channel, part);
        },
        .gpio => |part| {
            if (at != .gpio) return catalog.Error.WrongEndpoint;
            try board.pins.wired.attach(&board.pins, at.gpio.port, at.gpio.pin, part);
        },
    }
}
