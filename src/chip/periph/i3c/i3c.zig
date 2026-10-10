//! The I3C channel driven in legacy I2C mode (IIC_B): the controller a
//! polling driver clocks through CNDCTL / NTDTBP0 / NTST / BST.
//!
//! One channel, one transfer machine: START, the address byte, the payload
//! either way, then STOP. What answers on the line comes from the same
//! device registry the RIIC controller uses, so this file is only about
//! transfers, and the responder half lives in target.zig.
//!
//! RSTCTL IS A COMMAND REGISTER, NOT A SHADOW. Both drivers pulse
//! RSTCTL.RI3CRST before they configure anything, and both say the hardware
//! takes the bit back down again; one of them returns a timeout error when
//! it does not. Here the whole register just landed in the shadow and reset
//! nothing, so a channel left mid-transfer stayed mid-transfer through
//! bring-up: still busy, still holding the previous transaction's flags and
//! staged bytes. The rule and its evidence live in
//! src/chip/periph/i3c/reset.zig.
//!
//! dev drove this window from the data buffer alone. A byte written with no
//! START became an address and selected a part, a read past what the part
//! had to say kept the buffer flagged full and served zeros, and the two
//! condition-detect flags it declared were never raised at all, so a driver
//! waiting on one of them waited forever. Each of those is refused and
//! counted here instead.
const periph = @import("../registry.zig");
const bus = @import("../riic/bus.zig");
pub const flags = @import("flags.zig");
pub const regs = @import("regs.zig");
pub const target = @import("target.zig");
pub const reset = @import("reset.zig");

pub const win_base = flags.win_base;
pub const win_span = flags.win_span;
pub const reg = flags.reg;

/// Bytes a device may stage for one read. dev's own bound, and more than any
/// modelled part has to say.
pub const stage_bytes: usize = 64;

pub const I3c = struct {
    shadow: [flags.reg.words]u32 = @splat(0),
    /// The transmit side is empty out of reset, so a driver may put the
    /// first address byte down without waiting for anything.
    ntst: u32 = flags.ntst.tdbef0,
    bst: u32 = 0,
    busy: bool = false,
    addressed: bool = false,
    acked: bool = false,
    reading: bool = false,
    target_7b: u7 = 0,
    /// What the addressed device staged for this read.
    staged: [stage_bytes]u8 = @splat(0),
    staged_len: usize = 0,
    served: usize = 0,
    /// The receive flow does one dummy buffer read to start the clock before
    /// the first real byte.
    primed: bool = false,

    devices: bus.Registry = .{},
    /// The responder half, live once the firmware claims an own address.
    responder: target.Target = .{},

    /// Transactions that reached STOP with a device ACKing.
    transfers: u32 = 0,
    sent: u32 = 0,
    received: u32 = 0,
    /// Address bytes nothing on the bus answered. A scan is made of these.
    nacks: u32 = 0,
    /// Address bytes in the ranges I2C keeps for itself.
    reserved: u32 = 0,
    /// Buffer written with no transaction open. dev took the byte as an
    /// address and began a transfer nobody asked for.
    no_start: u32 = 0,
    /// START requested while a transaction was already open. dev tore the
    /// open one down and started again, losing a transfer silently.
    st_busy: u32 = 0,
    /// Repeated START on an idle bus. There is no condition to repeat; dev
    /// treated it as a plain START.
    rs_idle: u32 = 0,
    /// Buffer read past what the device had to say. dev kept the buffer
    /// flagged full and served zeros, so a driver reading too far got data
    /// that looked real.
    overdrain: u32 = 0,
    /// Software resets asked for through RSTCTL.
    resets: u32 = 0,
    /// Resets that arrived with a transaction still open. The reset is the
    /// point, so this is a count rather than a refusal: dev kept the
    /// transfer and the bit both.
    reset_busy: u32 = 0,
    /// A role change asked for while the other role was in the middle of
    /// something. This model carries one role at a time; dev let the
    /// responder take the data buffer out from under a live transfer, so the
    /// transfer moved nothing and said nothing about it.
    role_clash: u32 = 0,
    /// START requests while a part held the line low (`--fault ...=bus_low`,
    /// RA8EMU-537). No START can be put on a held bus, so none opens.
    held_starts: u32 = 0,

    pub fn quiet(self: *const I3c) bool {
        return self.transfers == 0 and self.nacks == 0 and self.reserved == 0 and
            self.no_start == 0 and self.st_busy == 0 and self.rs_idle == 0 and
            self.overdrain == 0 and self.role_clash == 0 and self.resets == 0 and
            self.held_starts == 0 and
            self.responder.quiet();
    }

    pub fn attachDevice(self: *I3c, device: bus.Device) bus.Error!void {
        try self.devices.attach(device);
    }

    fn openTransfer(self: *I3c) void {
        self.busy = true;
        self.addressed = false;
        self.acked = false;
        self.reading = false;
        self.staged_len = 0;
        self.served = 0;
        self.primed = false;
        // The transmit buffer is empty so the driver can put the address
        // byte in it, and the previous phase's outcome is not this one's.
        self.ntst = flags.ntst.tdbef0;
        self.bst &= ~(flags.bst.nackdf | flags.bst.tendf);
        self.bst |= flags.bst.stcnddf;
    }

    fn closeTransfer(self: *I3c) void {
        if (self.acked) {
            if (self.devices.find(self.target_7b)) |device| device.stop();
            self.transfers += 1;
        }
        self.busy = false;
        self.addressed = false;
        self.ntst = flags.ntst.tdbef0;
        self.bst |= flags.bst.spcnddf;
    }

    /// RSTCTL asks the channel back to idle. The bits are commands: they are
    /// acted on and spent, never stored. What comes back is the transfer
    /// machine out of reset, nothing addressed and nothing staged, with the
    /// buffer empty so the driver can put the first address byte down. The
    /// configuration shadow is deliberately left alone: ra8_i3c_i2c_init
    /// resets FIRST and applies its registers after, and the table saying
    /// which of them the reset restores is not in this tree. The responder
    /// half rides through for the same reason: what arms it is the own
    /// address in MSDVAD, which is configuration, and the way firmware
    /// gives that role back up is to write MSDVAD zero.
    fn softReset(self: *I3c, value: u32) void {
        if (!reset.requested(value)) return;
        self.resets += 1;
        if (self.busy) self.reset_busy += 1;
        if (!reset.resetsChannel(value)) return;
        self.busy = false;
        self.addressed = false;
        self.acked = false;
        self.reading = false;
        self.target_7b = 0;
        self.staged_len = 0;
        self.served = 0;
        self.primed = false;
        self.ntst = flags.ntst.tdbef0;
        self.bst = 0;
    }

    /// Software resets the channel took.
    pub fn resetCount(self: *const I3c) u32 {
        return self.resets;
    }

    /// The address byte after a (re)START selects a part and it either
    /// answers or it does not.
    fn addressPhase(self: *I3c, byte: u8) void {
        self.target_7b = bus.wire.addressOf(byte);
        self.reading = bus.wire.readingOf(byte);
        self.addressed = true;
        if (bus.reserved.holds(self.target_7b)) {
            self.acked = false;
            self.reserved += 1;
            self.bst |= flags.bst.nackdf;
            return;
        }
        // A part that does not acknowledge (a --fault disconnect) NACKs here.
        const device = self.devices.answering(self.target_7b) orelse {
            self.acked = false;
            self.nacks += 1;
            self.bst |= flags.bst.nackdf;
            return;
        };
        self.acked = true;
        self.bst |= flags.bst.tendf;
        if (!self.reading) {
            self.ntst |= flags.ntst.tdbef0;
            return;
        }
        self.staged_len = device.read(self.staged[0..]);
        self.served = 0;
        self.primed = false;
        if (self.staged_len != 0) self.ntst |= flags.ntst.rdbff0;
    }

    fn writeData(self: *I3c, byte: u8) void {
        if (self.responder.armed) return self.responder.transmit(byte);
        if (!self.busy) {
            self.no_start += 1;
            return;
        }
        if (!self.addressed) return self.addressPhase(byte);
        if (!self.acked) return;
        if (self.devices.answering(self.target_7b)) |device| device.write(byte);
        self.sent += 1;
        self.ntst |= flags.ntst.tdbef0;
    }

    fn readData(self: *I3c) u32 {
        if (self.responder.armed) return self.responder.receive();
        if (!self.primed) {
            self.primed = true;
            return 0;
        }
        if (self.served >= self.staged_len) {
            // Nothing left on the line. The full flag goes with the data.
            self.overdrain += 1;
            self.ntst &= ~flags.ntst.rdbff0;
            return 0;
        }
        const byte = self.staged[self.served];
        self.served += 1;
        self.received += 1;
        if (self.served < self.staged_len) {
            self.ntst |= flags.ntst.rdbff0;
        } else {
            self.ntst &= ~flags.ntst.rdbff0;
        }
        return byte;
    }

    /// CNDCTL carries the three condition requests. A START needs an idle
    /// bus and a repeated START needs a busy one; the request bits clear
    /// once the condition is issued, which is what the driver spins on.
    fn control(self: *I3c, value: u32) void {
        if (self.responder.armed) {
            self.role_clash += 1;
            return;
        }
        if (value & flags.cndctl.stcnd != 0) {
            if (self.devices.held_low) {
                // SCL/SDA held low: no START condition, and the request
                // bit stays set, so a driver spinning on it times out.
                self.held_starts += 1;
                return;
            }
            if (self.busy) self.st_busy += 1 else self.openTransfer();
        } else if (value & flags.cndctl.srcnd != 0) {
            if (self.busy) self.openTransfer() else self.rs_idle += 1;
        } else if (value & flags.cndctl.spcnd != 0) {
            if (self.busy) self.closeTransfer();
        }
        self.shadow[flags.reg.cndctl / 4] = 0;
    }

    /// The firmware claiming an own address is the firmware coming up as the
    /// addressed part. It may not do that on top of a live transfer.
    fn claimAddress(self: *I3c, value: u32) void {
        if (self.busy) {
            self.role_clash += 1;
            return;
        }
        self.responder.open(value);
    }

    /// The whole word an access lands in. The live registers answer for
    /// themselves and everything else reflects what was written, so
    /// "configure then verify" still works across the window.
    fn readWord(self: *I3c, access: regs.Access) u32 {
        return switch (access.word) {
            flags.reg.ntst => if (self.responder.armed) self.responder.status() else self.ntst,
            flags.reg.bst => self.bst,
            // A held line is never free (BCST.BFREF stays 0).
            flags.reg.bcst => if (self.busy or self.devices.held_low) 0 else flags.bcst.bfref,
            // The port moves a byte, and only for an access that reaches it.
            flags.reg.ntdtbp0 => if (access.carriesData()) self.readData() else 0,
            else => self.shadow[access.index()],
        };
    }

    pub fn read(self: *I3c, address: u32, width: u3) u32 {
        const offset = address -% flags.win_base;
        if (!regs.inside(offset)) return 0;
        const access = regs.Access.of(offset, width);
        return access.cut(self.readWord(access));
    }

    pub fn write(self: *I3c, address: u32, width: u3, value: u32) void {
        const offset = address -% flags.win_base;
        if (!regs.inside(offset)) return;
        const access = regs.Access.of(offset, width);
        const merged = access.fold(self.shadow[access.index()], value);
        // Every RSTCTL bit is spent on the write, so none of them reaches
        // the shadow and the driver's poll for a self-clear finishes.
        self.shadow[access.index()] =
            if (access.word == reset.off) reset.stored(merged) else merged;
        switch (access.word) {
            reset.off => self.softReset(merged),
            flags.reg.msdvad => self.claimAddress(merged),
            flags.reg.cndctl => self.control(merged),
            flags.reg.ntdtbp0 => if (access.carriesData()) self.writeData(regs.Access.dataByte(value)),
            // BST is write-0-to-clear, and only in the lanes this store named.
            flags.reg.bst => self.bst &= access.clearing(value),
            else => {},
        }
    }

    /// A whole-word access at a window offset, which is how the tests and the
    /// board's own wiring reach a register by name.
    pub fn readOffset(self: *I3c, offset: u32) u32 {
        return self.read(flags.win_base +% offset, 4);
    }

    pub fn writeOffset(self: *I3c, offset: u32, value: u32) void {
        self.write(flags.win_base +% offset, 4, value);
    }

    pub fn block(self: *I3c) periph.Block {
        return .{
            .name = "I3C",
            .base = flags.win_base,
            .size = flags.win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *I3c = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *I3c = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
