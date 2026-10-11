//! The Zig core's bus with the debugger listening (RA8EMU-113). The stop
//! machine needs every load and store; the Zig core owns no hooks, so this sits between the core and
//! its bus and does the same: a store reaches the debug units the firmware
//! programs (FPB, DWT, ITM, DCB) through Driver.stored, and every access
//! reaches the watches and the DWT comparators through Machine.onAccess.
//! A load of a unit's register reads what the machine holds (unit_view.zig).
//!
//! It listens only while armed, which zig_drive does around one
//! instruction, and never to that instruction's own fetch.
const std = @import("std");
const bus = @import("ra8_chip").core.cpu.bus;
const step_hook = @import("../step_hook.zig");
const until = @import("ra8_chip").core.until;
/// Re-exported for tests/session/unit_view_test.zig.
pub const unit_view = @import("../unit_view.zig");

pub const WatchBus = struct {
    inner: bus.Bus,
    driver: *step_hook.Driver,
    armed: bool = false,
    /// The instruction now running, whose fetch is not an access.
    fetch_from: u32 = 0,
    fetch_len: u32 = 0,
    /// Seen once an armed store lands in the PPB, where the debug units
    /// live: a quiet batch hands it to the core as its `until`, so a store
    /// that may arm the FPB or DWT ends the batch (RA8EMU-712).
    ppb: until.Until = .{ .needle = "" },
    /// Set over a quiet stretch, where no watch or comparator is armed: only
    /// the PPB, where the debug units live, is listened to (RA8EMU-712).
    quiet: bool = false,

    pub fn view(self: *WatchBus) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write, .latch = latch } };
    }

    /// Listen to the instruction at `pc`, `size` bytes wide.
    pub fn arm(self: *WatchBus, pc: u32, size: u8) void {
        self.armed = true;
        self.fetch_from = pc;
        self.fetch_len = size;
    }

    pub fn disarm(self: *WatchBus) void {
        self.armed = false;
    }

    fn fetching(self: *const WatchBus, address: u32) bool {
        return address >= self.fetch_from and address -% self.fetch_from < self.fetch_len;
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *WatchBus = @ptrCast(@alignCast(ctx));
        try self.inner.read(address, into);
        if (!self.armed or self.fetching(address)) return;
        if (self.quiet and address < ppb_base) return;
        unit_view.overlay(self.driver.machine, address, into);
        self.driver.loaded(address);
        self.driver.machine.onAccess(address, width(into.len), .read, value(into));
    }

    /// The core raising a fault status bit is not a guest access: no
    /// watchpoint sees it, and it stays a latch underneath (RA8EMU-634).
    fn latch(ctx: *anyopaque, address: u32, bits: u32) bus.Error!void {
        const self: *WatchBus = @ptrCast(@alignCast(ctx));
        return self.inner.latch(address, bits);
    }

    fn write(ctx: *anyopaque, address: u32, bytes: []const u8) bus.Error!void {
        const self: *WatchBus = @ptrCast(@alignCast(ctx));
        try self.inner.write(address, bytes);
        if (!self.armed) return;
        if (address >= ppb_base) self.ppb.seen = true else if (self.quiet) return;
        const moved = value(bytes);
        self.driver.stored(address, moved, width(bytes.len));
        self.driver.machine.onAccess(address, width(bytes.len), .write, moved);
    }
};

/// Where the Private Peripheral Bus starts.
const ppb_base: u32 = 0xE000_0000;

fn width(len: usize) u8 {
    return @intCast(@min(len, std.math.maxInt(u8)));
}

/// The low word an access moved, little-endian.
fn value(bytes: []const u8) u32 {
    var word: [4]u8 = .{ 0, 0, 0, 0 };
    const len = @min(bytes.len, word.len);
    @memcpy(word[0..len], bytes[0..len]);
    return std.mem.readInt(u32, &word, .little);
}
