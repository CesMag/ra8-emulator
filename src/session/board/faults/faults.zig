//! The session's fault hook for parts on this board's I2C lines (RA8EMU-520).
//!
//! The first set on a part wraps it where it sits in its line's registry, in
//! a fault.I2c on the run's clock. Every later set or clear only changes that
//! same wrapper's mode, so setting and clearing mid-run never stacks
//! wrappers; a cleared part passes straight through. bus_low is a fact about
//! the line, not the part: setting it holds the line low, and clearing any
//! part on that line lets it go. SPI and UART channels go through
//! session_faults_lines.zig.
const std = @import("std");
const endpoint = @import("ra8_components").endpoint;
const fault = @import("ra8_components").fault;
const fault_spec = @import("ra8_components").fault.spec;
const fault_lines = @import("ra8_components").fault.lines;
const riic_bus = @import("ra8_chip").periph.riic.bus;
const spi = @import("ra8_chip").periph.spi;
const sci = @import("ra8_chip").periph.sci;
const sci_device = @import("ra8_chip").periph.sci.device;
const lines = @import("lines.zig");
const Board = @import("ra8_board").board.Board;

pub const Error = error{ WrongEndpoint, NothingFitted, TooManyFaults } || lines.Error;

/// Parts that can carry a session fault at once: every slot on both lines.
pub const max_wrapped: usize = 2 * riic_bus.max_devices;

pub const Faults = struct {
    board: *Board,
    arena: std.mem.Allocator,
    wrapped: [max_wrapped]?*fault.I2c = @splat(null),
    spi_parts: lines.Wrappers(fault_lines.Spi, spi.Device, spi.channel_count) = .{},
    uart_parts: lines.Wrappers(fault_lines.Uart, sci_device.Device, sci.channels) = .{},

    pub fn init(board: *Board, arena: std.mem.Allocator) Faults {
        return .{ .board = board, .arena = arena };
    }

    /// Put the part on `at` into `mode`, or back to itself when null.
    pub fn set(self: *Faults, at: endpoint.Endpoint, mode: ?fault_spec.Mode) Error!void {
        switch (at) {
            .i2c => try self.setI2c(at, mode),
            .spi => |where| {
                const slot = &self.board.spi.channels[where.channel].device;
                try self.spi_parts.set(self.arena, where.channel, slot, try lines.lineMode(mode));
            },
            .uart => |where| {
                const slot = &self.board.serial.channels[where.channel].device;
                try self.uart_parts.set(self.arena, where.channel, slot, try lines.lineMode(mode));
            },
            .gpio => return Error.WrongEndpoint,
        }
    }

    fn setI2c(self: *Faults, at: endpoint.Endpoint, mode: ?fault_spec.Mode) Error!void {
        const registry = self.line(at.i2c.line);
        const found = registry.find(at.i2c.address) orelse return Error.NothingFitted;
        const wanted = mode orelse {
            registry.hold(false);
            if (self.wrapperOf(found)) |wrapper| wrapper.set(.none);
            return;
        };
        if (wanted == .bus_low) return registry.hold(true);
        const wrapper = try self.wrap(found);
        wrapper.set(fault_spec.i2cMode(wanted));
    }

    fn line(self: *Faults, which: endpoint.Line) *riic_bus.Registry {
        return switch (which) {
            .riic => &self.board.wire.controller.devices,
            .touch => &self.board.wire.touchline.devices,
        };
    }

    /// The wrapper this hook already put around `slot`, if any.
    fn wrapperOf(self: *Faults, slot: *riic_bus.Device) ?*fault.I2c {
        for (self.wrapped) |entry| {
            const wrapper = entry orelse continue;
            if (slot.context == @as(*anyopaque, wrapper)) return wrapper;
        }
        return null;
    }

    fn wrap(self: *Faults, slot: *riic_bus.Device) Error!*fault.I2c {
        if (self.wrapperOf(slot)) |wrapper| return wrapper;
        for (&self.wrapped) |*entry| {
            if (entry.* != null) continue;
            const wrapper = try self.arena.create(fault.I2c);
            wrapper.* = fault.I2c.timed(slot.*, &self.board.time.base);
            slot.* = wrapper.device();
            entry.* = wrapper;
            return wrapper;
        }
        return Error.TooManyFaults;
    }
};
