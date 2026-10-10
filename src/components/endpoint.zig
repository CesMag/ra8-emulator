//! Where a pluggable device model attaches: an I2C line and address, an SPI
//! channel and chip select, an SCI channel, or a GPIO pin.
//!
//! The text form is what a run's config and `--attach` name, so it reads the
//! way the board and the HUM name things:
//!
//!   i2c:riic@0x36     the RIIC controller's line, 7-bit address 0x36
//!   i2c:touch@0x6B    the I3C channel in legacy I2C mode (the touch line)
//!   spi:spi1@ssl0     SPI_B channel 1, chip select SSL0
//!   uart:sci3         SCI channel 3
//!   gpio:P006         port 0, pin 06 (the RA pin name)
//!
//! Parsing only says where; whether anything already answers there is the
//! bus registry's call when the model is attached.
const std = @import("std");
const riic_bus = @import("ra8_chip").periph.riic.bus;

pub const Kind = enum { i2c, spi, uart, gpio };

/// The board's two I2C lines (src/board/i2c.zig).
pub const Line = enum { riic, touch };

/// How many of each the RA8D2 has: SPI_B channels 0..1 with SSL0..3, SCI
/// channels 0..9, and ports 0..B with pins 00..15 (HUM Ch 19, 34, 36).
pub const limits = struct {
    pub const spi_channels: u8 = 2;
    pub const spi_selects: u8 = 4;
    pub const sci_channels: u8 = 10;
    pub const ports: u8 = 12;
    pub const pins: u8 = 16;
};

pub const Endpoint = union(Kind) {
    i2c: struct { line: Line, address: u7 },
    spi: struct { channel: u1, select: u2 },
    uart: struct { channel: u4 },
    gpio: struct { port: u4, pin: u4 },

    pub fn kind(self: Endpoint) Kind {
        return std.meta.activeTag(self);
    }

    /// The text `parse` reads back: i2c:riic@0x36, spi:spi1@ssl0,
    /// uart:sci3, gpio:P106.
    pub fn write(self: Endpoint, out: anytype) !void {
        switch (self) {
            .i2c => |i| try out.print("i2c:{s}@0x{X:0>2}", .{ @tagName(i.line), i.address }),
            .spi => |s| try out.print("spi:spi{d}@ssl{d}", .{ s.channel, s.select }),
            .uart => |u| try out.print("uart:sci{d}", .{u.channel}),
            .gpio => |g| try out.print("gpio:P{X}{d:0>2}", .{ g.port, g.pin }),
        }
    }
};

pub const Error = error{
    Malformed,
    UnknownKind,
    UnknownLine,
    BadNumber,
    OutOfRange,
    ReservedAddress,
};

pub fn parse(text: []const u8) Error!Endpoint {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return Error.Malformed;
    const where = text[colon + 1 ..];
    if (where.len == 0) return Error.Malformed;
    const kind = std.meta.stringToEnum(Kind, text[0..colon]) orelse return Error.UnknownKind;
    return switch (kind) {
        .i2c => parseI2c(where),
        .spi => parseSpi(where),
        .uart => .{ .uart = .{ .channel = @intCast(try prefixed(where, "sci", limits.sci_channels)) } },
        .gpio => parseGpio(where),
    };
}

fn parseI2c(where: []const u8) Error!Endpoint {
    const at = std.mem.indexOfScalar(u8, where, '@') orelse return Error.Malformed;
    const line = std.meta.stringToEnum(Line, where[0..at]) orelse return Error.UnknownLine;
    const value = std.fmt.parseInt(u8, where[at + 1 ..], 0) catch return Error.BadNumber;
    if (value > riic_bus.wire.addr_mask) return Error.OutOfRange;
    const address: u7 = @intCast(value);
    if (riic_bus.reserved.holds(address)) return Error.ReservedAddress;
    return .{ .i2c = .{ .line = line, .address = address } };
}

fn parseSpi(where: []const u8) Error!Endpoint {
    const at = std.mem.indexOfScalar(u8, where, '@') orelse return Error.Malformed;
    const channel = try prefixed(where[0..at], "spi", limits.spi_channels);
    const select = try prefixed(where[at + 1 ..], "ssl", limits.spi_selects);
    return .{ .spi = .{ .channel = @intCast(channel), .select = @intCast(select) } };
}

/// `P` then the port as one hex digit, then the pin as two decimal digits.
fn parseGpio(where: []const u8) Error!Endpoint {
    if (where.len != 4 or where[0] != 'P') return Error.Malformed;
    const port = std.fmt.charToDigit(where[1], 16) catch return Error.BadNumber;
    const pin = std.fmt.parseInt(u8, where[2..4], 10) catch return Error.BadNumber;
    if (port >= limits.ports or pin >= limits.pins) return Error.OutOfRange;
    return .{ .gpio = .{ .port = @intCast(port), .pin = @intCast(pin) } };
}

/// A name and a decimal index under `limit`: `sci3`, `ssl0`.
fn prefixed(text: []const u8, prefix: []const u8, limit: u8) Error!u8 {
    if (!std.mem.startsWith(u8, text, prefix)) return Error.Malformed;
    const digits = text[prefix.len..];
    if (digits.len == 0) return Error.Malformed;
    const value = std.fmt.parseInt(u8, digits, 10) catch return Error.BadNumber;
    if (value >= limit) return Error.OutOfRange;
    return value;
}
