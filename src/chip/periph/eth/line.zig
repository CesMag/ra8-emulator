//! The two lines a port drives off the chip (RA8EMU-1042): the MDIO bus
//! RMAC reaches the PHY over, and the wire the gateway's DMA sends frames on
//! and takes them from. The parts on the far side are the board's
//! (src/components/eth_phy); the chip holds only these.
const regs = @import("regs.zig");

/// What an idle MDIO bus reads as: nobody drives it low, so it floats high.
pub const idle_data: u16 = 0xFFFF;

/// The MDIO bus, as RMAC.MPSM drives it.
pub const Mdio = struct {
    context: *anyopaque,
    /// One management frame; returns what MPSM reads back afterwards.
    transactFn: *const fn (*anyopaque, u32) u32,

    pub fn transact(self: Mdio, mpsm: u32) u32 {
        return self.transactFn(self.context, mpsm);
    }
};

/// A management frame on a bus with no PHY on it: PSME clears, and a read
/// finds the idle level.
pub fn unanswered(mpsm: u32) u32 {
    const done = mpsm & ~regs.rmac.psme;
    const op: regs.Op = @fromBackingInt(@intCast(@as(u2, @truncate((mpsm >> regs.rmac.pop_shift)))));
    return if (op == .read) regs.withData(done, idle_data) else done;
}

/// The wire, from the firmware's side of it.
pub const Wire = struct {
    context: *anyopaque,
    /// The firmware's frame, out. False when the far end has no room.
    sendFn: *const fn (*anyopaque, []const u8) bool,
    /// How long the next inbound frame is, without taking it.
    waitingFn: *const fn (*anyopaque) ?u32,
    peekFn: *const fn (*anyopaque) ?[]const u8,
    /// Take the inbound frame at the front.
    dropFn: *const fn (*anyopaque) void,

    pub fn send(self: Wire, frame: []const u8) bool {
        return self.sendFn(self.context, frame);
    }

    pub fn waiting(self: Wire) ?u32 {
        return self.waitingFn(self.context);
    }

    pub fn peek(self: Wire) ?[]const u8 {
        return self.peekFn(self.context);
    }

    pub fn drop(self: Wire) void {
        self.dropFn(self.context);
    }
};
