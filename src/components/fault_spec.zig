//! One `--fault NAME@ENDPOINT=MODE` ask, and putting a made device into it
//! (RA8EMU-518).
//!
//! The split is at the last '=': an endpoint carries ':' and '@' of its own
//! (`i2c:riic@0x37`) and so does a mode's argument (`stuck:0xA5`), so '=' is
//! the one place the two halves can meet. The left half is an `--attach`
//! ask and goes through that parser, so a typo fails the same way.
//!
//! `@ENDPOINT=MODE` with no name is the part the board fitted at that I2C
//! endpoint (RA8EMU-536), so a stock image's own I2C path can be faulted.
//!
//! Modes: disconnected, nack:N, stuck:0xHH, garbage:SEED, slow:NS,
//! stretch:NS, bus_low.
//! A mode that does not fit the device's bus is refused here, before the
//! run starts, rather than quietly doing nothing.
const std = @import("std");
const catalog = @import("catalog.zig");
const request = @import("request.zig");
const endpoint = @import("endpoint.zig");
const fault = @import("fault.zig");
const fault_lines = @import("fault_lines.zig");
const timebase = @import("ra8_chip").periph.timebase;

pub const Mode = union(enum) {
    disconnected,
    nack_every: u32,
    stuck: u8,
    garbage: u32,
    slow_ns: u64,
    stretch_ns: u64,
    /// Holds the shared I2C bus low rather than wrapping the part.
    bus_low,
};

pub const Fault = struct {
    target: request.Request,
    mode: Mode,
};

pub const Error = error{ NoMode, UnknownMode, BadArgument, WrongBus, NoSuchAttach } ||
    request.Error || std.mem.Allocator.Error;

pub fn parse(text: []const u8) Error!Fault {
    const split = std.mem.lastIndexOfScalar(u8, text, '=') orelse return Error.NoMode;
    return .{
        .target = try target(text[0..split]),
        .mode = try parseMode(text[split + 1 ..]),
    };
}

/// A named `--attach` ask, or `@ENDPOINT` for the fitted part there. Fitted
/// parts are only reachable on the I2C lines' registries.
fn target(text: []const u8) Error!request.Request {
    if (text.len == 0 or text[0] != '@') return request.parse(text);
    const at = try endpoint.parse(text[1..]);
    if (at != .i2c) return Error.WrongBus;
    return .{ .name = "", .at = at };
}

/// Put a fault on the `--attach` ask it names, same model at the same
/// endpoint. The ask has to come first; a later fault replaces an earlier.
pub fn place(asks: []request.Request, wanted: Fault) Error!void {
    for (asks) |*ask| {
        if (!std.mem.eql(u8, ask.name, wanted.target.name)) continue;
        if (!std.meta.eql(ask.at, wanted.target.at)) continue;
        ask.fault = wanted.mode;
        return;
    }
    return Error.NoSuchAttach;
}

pub fn parseMode(text: []const u8) Error!Mode {
    if (text.len == 0) return Error.NoMode;
    const colon = std.mem.indexOfScalar(u8, text, ':');
    const word = text[0 .. colon orelse text.len];
    const arg: ?[]const u8 = if (colon) |at| text[at + 1 ..] else null;
    if (std.mem.eql(u8, word, "disconnected")) return bare(arg, .disconnected);
    if (std.mem.eql(u8, word, "bus_low")) return bare(arg, .bus_low);
    if (std.mem.eql(u8, word, "nack")) {
        // A period of zero would never NACK: a typo, not a mode.
        const every = try number(u32, arg);
        return if (every == 0) Error.BadArgument else .{ .nack_every = every };
    }
    if (std.mem.eql(u8, word, "stuck")) return .{ .stuck = try number(u8, arg) };
    if (std.mem.eql(u8, word, "garbage")) return .{ .garbage = try number(u32, arg) };
    if (std.mem.eql(u8, word, "slow")) return .{ .slow_ns = try number(u64, arg) };
    if (std.mem.eql(u8, word, "stretch")) return .{ .stretch_ns = try number(u64, arg) };
    return Error.UnknownMode;
}

fn bare(arg: ?[]const u8, mode: Mode) Error!Mode {
    if (arg != null) return Error.BadArgument;
    return mode;
}

/// A mode's argument: required, and 0x/0b/0o prefixes are taken.
fn number(comptime T: type, arg: ?[]const u8) Error!T {
    const text = arg orelse return Error.BadArgument;
    return std.fmt.parseInt(T, text, 0) catch Error.BadArgument;
}

/// Whether `mode` is something a device on this bus can do. bus_low is an
/// I2C bus fact the caller applies to the bus, not to the part.
pub fn fits(mode: Mode, device: catalog.Device) bool {
    return switch (device) {
        .i2c => true,
        .spi, .uart => switch (mode) {
            .disconnected, .stuck, .garbage => true,
            else => false,
        },
        .gpio => false,
    };
}

/// Wrap a made device in its fault. The wrapper comes from `arena` and
/// lives as long as the run. bus_low has nothing to wrap, so the device
/// goes back as it was and the caller holds the bus.
pub fn apply(
    arena: std.mem.Allocator,
    device: catalog.Device,
    mode: Mode,
    clock: *const timebase.TimeBase,
) Error!catalog.Device {
    if (!fits(mode, device)) return Error.WrongBus;
    if (mode == .bus_low) return device;
    return switch (device) {
        .i2c => |inner| blk: {
            const wrapper = try arena.create(fault.I2c);
            wrapper.* = fault.I2c.timed(inner, clock);
            wrapper.set(i2cMode(mode));
            break :blk .{ .i2c = wrapper.device() };
        },
        .spi => |inner| blk: {
            const wrapper = try arena.create(fault_lines.Spi);
            wrapper.* = fault_lines.Spi.wrap(inner);
            wrapper.set(lineMode(mode));
            break :blk .{ .spi = wrapper.device() };
        },
        .uart => |inner| blk: {
            const wrapper = try arena.create(fault_lines.Uart);
            wrapper.* = fault_lines.Uart.wrap(inner);
            wrapper.set(lineMode(mode));
            break :blk .{ .uart = wrapper.device() };
        },
        .gpio => Error.WrongBus,
    };
}

/// The I2C wrapper's mode for a `--fault` mode; bus_low is the line's, so
/// the part itself behaves.
pub fn i2cMode(mode: Mode) fault.Mode {
    return switch (mode) {
        .disconnected => .disconnected,
        .nack_every => |n| .{ .nack_every = n },
        .stuck => |v| .{ .stuck = v },
        .garbage => |s| .{ .garbage = s },
        .slow_ns => |ns| .{ .slow_ns = ns },
        .stretch_ns => |ns| .{ .stretch_ns = ns },
        .bus_low => .none,
    };
}

fn lineMode(mode: Mode) fault_lines.LineMode {
    return switch (mode) {
        .disconnected => .disconnected,
        .stuck => |v| .{ .stuck = v },
        .garbage => |s| .{ .garbage = s },
        else => .none,
    };
}
