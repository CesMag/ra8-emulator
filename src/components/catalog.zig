//! The device models a run can attach by name, and how one is made.
//!
//! A model is a part that is not soldered to the board: a sensor on a Click
//! module, a flash chip, a second fuel gauge. The bus controllers already
//! take their devices through one seam each (riic_bus.Device, spi.Device,
//! sci_device.Device, gpio_pins.Device), so the catalog adds no seam of its own. It names a
//! model, says which kind of endpoint it plugs into, and makes an instance
//! that hands back that bus's Device. The controllers never learn that a
//! model exists.
const std = @import("std");
const endpoint = @import("endpoint.zig");
const riic_bus = @import("ra8_chip").periph.riic.bus;
const sci_device = @import("ra8_chip").periph.sci.device;
const spi = @import("ra8_chip").periph.spi;
const gpio_pins = @import("ra8_chip").periph.gpio.pins;

/// What an instance offers its bus or pin.
pub const Device = union(enum) {
    i2c: riic_bus.Device,
    spi: spi.Device,
    uart: sci_device.Device,
    gpio: gpio_pins.Device,
};

/// One attached model: the device its bus talks to and the state behind
/// it, which `Catalog.destroy` gives back.
pub const Instance = struct {
    model: *const Model,
    device: Device,
    state: *anyopaque,
};

/// A model owns its state (create, destroy) apart from where it sits on a
/// bus (bind), so a board can bind storage it already holds and a run can
/// make a fresh instance for each extra endpoint.
pub const Model = struct {
    name: []const u8,
    kind: endpoint.Kind,
    createFn: *const fn (std.mem.Allocator) Error!*anyopaque,
    destroyFn: *const fn (std.mem.Allocator, *anyopaque) void,
    /// The device for this state at this endpoint. The endpoint is already
    /// known to be of `kind`.
    bindFn: *const fn (*anyopaque, endpoint.Endpoint) Device,
};

pub const Error = error{
    UnknownModel,
    WrongEndpoint,
    OutOfMemory,
};

pub const Catalog = struct {
    models: []const Model,

    pub fn find(self: Catalog, name: []const u8) ?*const Model {
        for (self.models) |*model| {
            if (std.mem.eql(u8, model.name, name)) return model;
        }
        return null;
    }

    /// A model that exists and plugs into this kind of endpoint.
    fn fitting(self: Catalog, name: []const u8, at: endpoint.Endpoint) Error!*const Model {
        const model = self.find(name) orelse return Error.UnknownModel;
        if (model.kind != at.kind()) return Error.WrongEndpoint;
        return model;
    }

    /// A fresh instance of `name` at `at`; give it back with `destroy`.
    pub fn make(
        self: Catalog,
        allocator: std.mem.Allocator,
        name: []const u8,
        at: endpoint.Endpoint,
    ) Error!Instance {
        const model = try self.fitting(name, at);
        const state = try model.createFn(allocator);
        return .{ .model = model, .device = model.bindFn(state, at), .state = state };
    }

    /// The device of `name` over state the caller holds. `state` must be
    /// that model's own state type.
    pub fn bind(self: Catalog, name: []const u8, state: *anyopaque, at: endpoint.Endpoint) Error!Device {
        const model = try self.fitting(name, at);
        return model.bindFn(state, at);
    }

    pub fn destroy(allocator: std.mem.Allocator, instance: Instance) void {
        instance.model.destroyFn(allocator, instance.state);
    }
};
