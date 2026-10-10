//! A bus that counts stores and latches apart, for the tests that check a
//! wrapper passes the core's fault latch through as a latch (RA8EMU-634).
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;

pub const Latches = struct {
    writes: u32 = 0,
    latched: u32 = 0,
    at: u32 = 0,

    pub fn view(self: *Latches) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write, .latch = latch } };
    }

    fn read(_: *anyopaque, _: u32, into: []u8) bus.Error!void {
        @memset(into, 0);
    }

    fn write(ctx: *anyopaque, _: u32, _: []const u8) bus.Error!void {
        const self: *Latches = @ptrCast(@alignCast(ctx));
        self.writes += 1;
    }

    fn latch(ctx: *anyopaque, address: u32, bits: u32) bus.Error!void {
        const self: *Latches = @ptrCast(@alignCast(ctx));
        self.at = address;
        self.latched |= bits;
    }
};
