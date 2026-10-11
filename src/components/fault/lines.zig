//! Fault modes for a device on an SPI or UART line (RA8EMU-214, slice
//! RA8EMU-521). The I2C wrapper is fault.zig; this is the same idea on the
//! two seams that have no acknowledge, so there is no NACK mode here.
//!
//! Disconnected means the part hears nothing: an SPI frame reads back the
//! idle-high CIPO (0xFF) and a UART line goes silent. Stuck and garbage let
//! the part hear its bytes and rewrite what it sends back.
const fault = @import("fault.zig");
const spi = @import("ra8_chip").periph.spi;
const sci_device = @import("ra8_chip").periph.sci.device;

pub const LineMode = union(enum) {
    none,
    disconnected,
    stuck: u8,
    garbage: u32,
};

/// What an unpulled CIPO reads with nothing driving it.
pub const floating: u8 = 0xFF;

/// The most of one UART reply a fault rewrites. A longer reply is cut here
/// while a stuck or garbage mode is on.
pub const reply_cap: usize = 256;

pub const Spi = struct {
    inner: spi.Device,
    mode: LineMode = .none,
    noise: u32 = 0,

    pub fn wrap(inner: spi.Device) Spi {
        return .{ .inner = inner };
    }

    pub fn set(self: *Spi, mode: LineMode) void {
        self.mode = mode;
        if (mode == .garbage) self.noise = mode.garbage | 1;
    }

    pub fn device(self: *Spi) spi.Device {
        return .{ .context = self, .exchangeFn = exchange };
    }

    fn exchange(context: *anyopaque, byte: u8) u8 {
        const self: *Spi = @ptrCast(@alignCast(context));
        if (self.mode == .disconnected) return floating;
        const back = self.inner.exchange(byte);
        return switch (self.mode) {
            .stuck => |value| value,
            .garbage => fault.noiseByte(&self.noise),
            else => back,
        };
    }
};

pub const Uart = struct {
    inner: sci_device.Device,
    mode: LineMode = .none,
    noise: u32 = 0,
    reply: [reply_cap]u8 = undefined,

    pub fn wrap(inner: sci_device.Device) Uart {
        return .{ .inner = inner };
    }

    pub fn set(self: *Uart, mode: LineMode) void {
        self.mode = mode;
        if (mode == .garbage) self.noise = mode.garbage | 1;
    }

    pub fn device(self: *Uart) sci_device.Device {
        return .{ .context = self, .feedFn = feed, .spi_only = self.inner.spi_only };
    }

    fn feed(context: *anyopaque, byte: u8) []const u8 {
        const self: *Uart = @ptrCast(@alignCast(context));
        if (self.mode == .disconnected) return &.{};
        const said = self.inner.feed(byte);
        const out = self.reply[0..@min(said.len, reply_cap)];
        switch (self.mode) {
            .stuck => |value| @memset(out, value),
            .garbage => for (out) |*b| {
                b.* = fault.noiseByte(&self.noise);
            },
            else => return said,
        }
        return out;
    }
};
