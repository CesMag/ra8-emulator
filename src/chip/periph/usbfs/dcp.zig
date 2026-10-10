//! The USBFS control FIFO port as the device side uses it: CFIFOSEL aimed at
//! the DCP, CFIFOCTR for the buffer state, and CFIFO for the bytes.
//!
//! Only the DCP is behind this port here; a CURPIPE other than 0 aims it at
//! nothing and every access through it is refused. The driver stages an IN
//! data stage with ISEL set and commits it with BVAL, which hands the packet
//! to the host on the other jack. An OUT data stage arrives from that host
//! and the driver reads it with ISEL clear. The byte handling is the USBHS
//! port's, so a byte crosses the same code on either controller.
const fifo = @import("../usbhs/fifo.zig");
const regs = @import("../usbhs/regs.zig");

pub const Dcp = struct {
    /// What the driver is staging for the host.
    in: fifo.Staging = .{},
    /// What the host sent, waiting for the driver.
    out: fifo.Staging = .{},
    /// The last IN packet committed with BVAL, until the host takes it.
    sent: fifo.Staging = .{},
    /// CFIFOSEL as written.
    sel: u16 = 0,
    /// The DCP's packet size; the full-speed control default.
    maxp: u16 = 64,
    packets_sent: u32 = 0,
    /// BRDYSTS.PIPE0BRDY: an OUT packet is in the buffer for the driver.
    brdy: bool = false,
    /// BEMPSTS.PIPE0BEMP: the host took the IN packet and the buffer is empty.
    bemp: bool = false,

    /// Accesses refused, each for its own reason.
    bad_pipe: u32 = 0,
    not_ready: u32 = 0,
    overdrain: u32 = 0,
    oversize: u32 = 0,

    fn aimed(self: *const Dcp) bool {
        return self.sel & regs.fifo.curpipe_mask == 0;
    }

    /// ISEL: the port faces the IN side, the one the driver writes.
    fn writing(self: *const Dcp) bool {
        return self.sel & regs.fifo.isel != 0;
    }

    pub fn select(self: *Dcp, value: u16) void {
        self.sel = value;
        if (!self.aimed()) self.bad_pipe += 1;
    }

    /// CFIFOCTR: FRDY while aimed at the DCP, and DTLN for the side faced:
    /// bytes staged so far on IN, bytes left to read on OUT. The DCP has
    /// one buffer, so the IN side is not ready while a committed packet is
    /// still waiting for the host. A driver that polls FRDY before staging
    /// the next packet of a multi-packet data stage waits there, instead of
    /// overwriting the packet the host has not taken.
    pub fn status(self: *const Dcp) u16 {
        if (!self.aimed()) return 0;
        if (self.writing() and self.sent.ready) return self.in.len & regs.fifo.dtln_mask;
        const length = if (self.writing()) self.in.len else self.out.remaining();
        return regs.fifo.frdy | (length & regs.fifo.dtln_mask);
    }

    /// CFIFOCTR writes: BCLR empties the side faced, BVAL commits an IN packet.
    pub fn control(self: *Dcp, value: u16) void {
        if (!self.aimed()) {
            self.bad_pipe += 1;
            return;
        }
        if (value & regs.fifo.bclr != 0) {
            if (self.writing()) self.in.clear() else self.out.clear();
        }
        if (value & regs.fifo.bval != 0 and self.writing()) self.commit();
    }

    fn commit(self: *Dcp) void {
        self.sent.fill(self.in.staged());
        self.in.clear();
        self.packets_sent += 1;
    }

    pub fn writeData(self: *Dcp, value: u32, width: u3) void {
        if (!self.aimed() or !self.writing()) {
            self.bad_pipe += 1;
            return;
        }
        fifo.fillWord(&self.in, value, width, self.maxp, &self.oversize);
    }

    pub fn readData(self: *Dcp, width: u3) u32 {
        if (!self.aimed() or self.writing()) {
            self.bad_pipe += 1;
            return 0;
        }
        if (!self.out.ready) {
            self.not_ready += 1;
            return 0;
        }
        return fifo.drainWord(&self.out, width, &self.overdrain);
    }

    /// An OUT data packet from the host lands in the DCP buffer.
    pub fn hostOut(self: *Dcp, bytes: []const u8) void {
        self.out.fill(bytes);
        self.brdy = true;
    }

    /// The host takes the packet the driver committed, if there is one.
    pub fn hostTake(self: *Dcp, into: []u8) ?u16 {
        if (!self.sent.ready) return null;
        self.bemp = true;
        return self.sent.drain(into);
    }

    /// INTSTS0.BRDY and BEMP: each is set while its pipe's status bit is.
    pub fn summary(self: *const Dcp) u16 {
        const ready: u16 = if (self.brdy) regs.int0.brdy else 0;
        const empty: u16 = if (self.bemp) regs.int0.bemp else 0;
        return ready | empty;
    }

    pub fn refusals(self: *const Dcp) u32 {
        return self.bad_pipe + self.not_ready + self.overdrain + self.oversize;
    }
};
