//! Fault modes for a device on the I2C seam (RA8EMU-214, slice RA8EMU-522).
//!
//! A fault wraps a device's own seam rather than living in the part, so the
//! part stays about the part and any model can be made to misbehave the same
//! way. The wrapper hands the controller a riic_bus.Device of its own: it
//! decides whether an address phase is acknowledged, and it can rewrite what
//! a read hands back. Everything else goes straight through.
//!
//! Garbage is seeded, so a run with a fault on it repeats exactly.
const riic_bus = @import("ra8_chip").periph.riic.bus;
const timebase = @import("ra8_chip").periph.timebase;

pub const Mode = union(enum) {
    /// Behave like the part.
    none,
    /// Gone from the bus: no address phase is acknowledged.
    disconnected,
    /// NACK every Nth address phase (1 is every one) and ACK the rest.
    nack_every: u32,
    /// Every byte read back is this value.
    stuck: u8,
    /// Every byte read back is noise from this seed.
    garbage: u32,
    /// Busy this many virtual ns after each write transaction ends, and
    /// NACK every address phase until then: the ACK polling a driver does
    /// on a slow part (RA8EMU-517). Needs the wrapper's clock.
    slow_ns: u64,
    /// Hold SCL low this many virtual ns before each byte read back: clock
    /// stretching (RA8EMU-532). The controller waits on the board clock.
    stretch_ns: u64,
};

pub const I2c = struct {
    inner: riic_bus.Device,
    mode: Mode = .none,
    /// Address phases seen, and how many of them were refused.
    phases: u32 = 0,
    refused: u32 = 0,
    noise: u32 = 0,
    /// The board's virtual time, for the slow mode. Without it a slow part
    /// is never busy, since there is no time to be busy for.
    clock: ?*const timebase.TimeBase = null,
    /// When a slow part answers again, and whether this transaction wrote.
    ready_at: u64 = 0,
    wrote: bool = false,

    pub fn wrap(inner: riic_bus.Device) I2c {
        return .{ .inner = inner };
    }

    pub fn timed(inner: riic_bus.Device, clock: *const timebase.TimeBase) I2c {
        return .{ .inner = inner, .clock = clock };
    }

    /// Put the device into `mode`. A garbage seed restarts its noise.
    pub fn set(self: *I2c, mode: Mode) void {
        self.mode = mode;
        if (mode == .garbage) self.noise = mode.garbage | 1;
    }

    pub fn device(self: *I2c) riic_bus.Device {
        return .{
            .address = self.inner.address,
            .context = self,
            .writeFn = write,
            .readFn = read,
            .stopFn = stop,
            .ackFn = ack,
            .stretchFn = stretch,
        };
    }

    fn stretch(context: *anyopaque) u64 {
        const self: *I2c = @ptrCast(@alignCast(context));
        return if (self.mode == .stretch_ns) self.mode.stretch_ns else 0;
    }

    fn ack(context: *anyopaque) bool {
        const self: *I2c = @ptrCast(@alignCast(context));
        self.phases += 1;
        const answers = switch (self.mode) {
            .disconnected => false,
            .nack_every => |every| every == 0 or self.phases % every != 0,
            .slow_ns => self.now() >= self.ready_at,
            else => true,
        } and self.inner.acks();
        if (!answers) self.refused += 1;
        return answers;
    }

    fn write(context: *anyopaque, byte: u8) void {
        const self: *I2c = @ptrCast(@alignCast(context));
        self.wrote = true;
        self.inner.write(byte);
    }

    fn read(context: *anyopaque, into: []u8) usize {
        const self: *I2c = @ptrCast(@alignCast(context));
        const given = self.inner.read(into);
        switch (self.mode) {
            .stuck => |value| @memset(into[0..given], value),
            .garbage => for (into[0..given]) |*byte| {
                byte.* = self.nextNoise();
            },
            else => {},
        }
        return given;
    }

    fn stop(context: *anyopaque) void {
        const self: *I2c = @ptrCast(@alignCast(context));
        if (self.mode == .slow_ns and self.wrote and self.clock != null) {
            self.ready_at = self.now() + self.mode.slow_ns;
        }
        self.wrote = false;
        self.inner.stop();
    }

    fn now(self: *const I2c) u64 {
        const clock = self.clock orelse return 0;
        return clock.now();
    }

    fn nextNoise(self: *I2c) u8 {
        return noiseByte(&self.noise);
    }
};

/// xorshift32: cheap, and the same sequence for the same seed. Shared by
/// every wrapper so a seed means the same noise on any line.
pub fn noiseByte(state: *u32) u8 {
    var x = state.*;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    state.* = x;
    return @truncate(x);
}
