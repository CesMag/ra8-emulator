//! The board's two I2C lines: the RIIC controller with the two parts the
//! EK-RA8D2 puts on it, the PI4IOE5V6408 port expander (U15) and the camera's
//! SCCB side, and the I3C channel driven in legacy I2C mode with the carrier's
//! GT911 touch controller on it.
//!
//! The controller knows about transfers, not about parts. Which parts a board
//! populates is a board fact, so it lives here rather than in riic.zig.
//!
//! THE IMU AND THE FUEL GAUGE ARE NOT BOARD FACTS. The LSM6DSO and the
//! MAX17048 are Click-module parts, not soldered to the EK-RA8D2, so a bench
//! with no module fitted answers nothing at 0x6B or 0x36. They go on the line
//! only when the run asks for them with `click`; by default those addresses
//! stay silent, the same as the bench.
const bus = @import("ra8_chip").periph.riic_bus;
const catalog = @import("../components/catalog.zig");
const endpoint = @import("../components/endpoint.zig");
const gt911 = @import("../components/touch_gt911/gt911.zig");
const i3c = @import("ra8_chip").periph.i3c;
const lsm6dso = @import("../components/imu_lsm6dso/lsm6dso.zig");
const max17048 = @import("../components/gauge_max17048/max17048.zig");
const ov5640 = @import("../components/camera_ov5640/ov5640_sccb.zig");
const parts = @import("../components/parts.zig");
const periph = @import("ra8_chip").periph.registry;
const pi4ioe = @import("../components/expander_pi4ioe/pi4ioe.zig");
const riic = @import("ra8_chip").periph.riic;
const timebase = @import("ra8_chip").periph.timebase;

pub const Wire = struct {
    controller: riic.Riic = riic.Riic.init(),
    expander: pi4ioe.Expander = .{},
    sensor: ov5640.Sensor = .{},
    /// The I3C channel in legacy I2C mode, and the parts on it: the touch
    /// panel always, the IMU and the fuel gauge only with `click` set.
    touchline: i3c.I3c = .{},
    panel: gt911.Panel = .{},
    imu: lsm6dso.Imu = .{},
    gauge: max17048.Gauge = .{},
    /// Whether a Click module carrying the IMU and the fuel gauge is fitted.
    /// Read by `attach`, so it is set before the board is wired.
    click: bool = false,

    /// Put both lines and the board's parts on the bus. The blocks hold
    /// pointers into this struct, so this runs once the board has stopped
    /// moving.
    pub fn attach(self: *Wire, window: *periph.Bus) !void {
        try window.add(self.block());
        try window.add(self.touchBlock());
        try self.controller.attachDevice(self.expander.device());
        try self.controller.attachDevice(self.sensor.device());
        try self.touchline.attachDevice(self.panel.device());
        if (self.click) {
            try self.fit(parts.imu_name, &self.imu, lsm6dso.address);
            try self.fit(parts.gauge_name, &self.gauge, max17048.address);
        }
    }

    /// Point every RIIC channel's receive path at the board's virtual time,
    /// so a part that stretches the clock lands its bytes on it.
    pub fn clock(self: *Wire, base: *const timebase.TimeBase) void {
        for (&self.controller.channels) |*channel| channel.rx.clock = base;
    }

    /// Bind a Click part this struct holds through the model catalog, at its
    /// datasheet address on the touch line where the module's I2C pins land.
    fn fit(self: *Wire, name: []const u8, state: *anyopaque, address: u7) !void {
        const at: endpoint.Endpoint = .{ .i2c = .{ .line = .touch, .address = address } };
        try self.plug(try parts.all.bind(name, state, at), at);
    }

    /// Put a catalog model's device on the I2C line its endpoint names.
    pub fn plug(self: *Wire, device: catalog.Device, at: endpoint.Endpoint) !void {
        const part = switch (device) {
            .i2c => |part| part,
            else => return catalog.Error.WrongEndpoint,
        };
        if (at != .i2c) return catalog.Error.WrongEndpoint;
        switch (at.i2c.line) {
            .riic => try self.controller.attachDevice(part),
            .touch => try self.touchline.attachDevice(part),
        }
    }

    pub fn block(self: *Wire) periph.Block {
        return self.controller.block();
    }

    pub fn touchBlock(self: *Wire) periph.Block {
        return self.touchline.block();
    }

    pub fn quiet(self: *const Wire) bool {
        return self.controller.quiet() and self.expander.quiet() and self.sensor.quiet() and
            self.touchline.quiet() and self.panel.quiet() and self.imu.quiet() and
            self.gauge.quiet();
    }
};
