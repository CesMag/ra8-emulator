//! The USBFS CFIFO port aimed at a bulk or interrupt pipe: CFIFOSEL.CURPIPE
//! 1 through 9, the way the USBX device driver moves endpoint data
//! (port/usbx ux_dcd_ra8_usb_xfer.c).
//!
//! For these pipes ISEL does not pick the side; the pipe's PIPECFG.DIR does.
//! An IN pipe is the one the driver writes: it stages a packet and commits
//! it with BVAL, and the host on the other jack takes it, which sets the
//! pipe's BEMPSTS bit. An OUT pipe is the one the driver reads: a packet
//! from the host lands there and sets the pipe's BRDYSTS bit. Each pipe has
//! one buffer, so an IN pipe is not ready while a committed packet waits,
//! and a host packet for an OUT pipe still holding one is refused.
//! The byte handling is the USBHS port's, as on the DCP.
const fifo = @import("../usbhs/fifo.zig");
const regs = @import("../usbhs/regs.zig");
const pipe = @import("pipe.zig");

const count = pipe.count;

pub const Bulk = struct {
    /// What the driver is staging on each IN pipe.
    in: [count]fifo.Staging = @splat(.{}),
    /// The packet committed with BVAL on each IN pipe, until the host takes it.
    sent: [count]fifo.Staging = @splat(.{}),
    /// What the host sent on each OUT pipe, waiting for the driver.
    out: [count]fifo.Staging = @splat(.{}),
    /// BRDYSTS and BEMPSTS, one bit per pipe with bit n for PIPEn.
    brdy: u16 = 0,
    bemp: u16 = 0,
    packets_sent: u32 = 0,

    /// Accesses refused, each for its own reason.
    bad_pipe: u32 = 0,
    not_ready: u32 = 0,
    overdrain: u32 = 0,
    oversize: u32 = 0,
    overrun: u32 = 0,

    /// CFIFOCTR for pipe n: FRDY and DTLN for the pipe's own side.
    pub fn status(self: *const Bulk, pipes: *const pipe.Pipes, n: u4) u16 {
        const p = opened(pipes, n) orelse return 0;
        const i = n - 1;
        if (p.in()) {
            const length = self.in[i].len & regs.fifo.dtln_mask;
            return if (self.sent[i].ready) length else regs.fifo.frdy | length;
        }
        return regs.fifo.frdy | (self.out[i].remaining() & regs.fifo.dtln_mask);
    }

    /// CFIFOCTR writes: BCLR empties the pipe's side, BVAL commits an IN packet.
    pub fn control(self: *Bulk, pipes: *const pipe.Pipes, n: u4, value: u16) void {
        const p = opened(pipes, n) orelse {
            self.bad_pipe += 1;
            return;
        };
        const i = n - 1;
        if (value & regs.fifo.bclr != 0) {
            if (p.in()) self.in[i].clear() else self.out[i].clear();
        }
        if (value & regs.fifo.bval != 0 and p.in()) {
            self.sent[i].fill(self.in[i].staged());
            self.in[i].clear();
            self.packets_sent += 1;
        }
    }

    pub fn writeData(self: *Bulk, pipes: *const pipe.Pipes, n: u4, value: u32, width: u3) void {
        const p = opened(pipes, n) orelse {
            self.bad_pipe += 1;
            return;
        };
        if (!p.in()) {
            self.bad_pipe += 1;
            return;
        }
        fifo.fillWord(&self.in[n - 1], value, width, p.max_packet, &self.oversize);
    }

    pub fn readData(self: *Bulk, pipes: *const pipe.Pipes, n: u4, width: u3) u32 {
        const p = opened(pipes, n) orelse {
            self.bad_pipe += 1;
            return 0;
        };
        if (p.in()) {
            self.bad_pipe += 1;
            return 0;
        }
        const staging = &self.out[n - 1];
        if (!staging.ready) {
            self.not_ready += 1;
            return 0;
        }
        return fifo.drainWord(staging, width, &self.overdrain);
    }

    /// A packet from the host for pipe n. False when the pipe is not an
    /// opened OUT pipe or its buffer still holds the last packet.
    pub fn hostOut(self: *Bulk, pipes: *const pipe.Pipes, n: u4, bytes: []const u8) bool {
        const p = opened(pipes, n) orelse return false;
        if (p.in()) return false;
        if (self.out[n - 1].ready) {
            self.overrun += 1;
            return false;
        }
        self.out[n - 1].fill(bytes);
        self.brdy |= bit(n);
        return true;
    }

    /// The host takes the packet committed on pipe n, if there is one.
    pub fn hostTake(self: *Bulk, n: u4, into: []u8) ?u16 {
        if (n == 0 or n > count) return null;
        if (!self.sent[n - 1].ready) return null;
        self.bemp |= bit(n);
        return self.sent[n - 1].drain(into);
    }

    /// INTSTS0.BRDY and BEMP while any pipe's bit stands.
    pub fn summary(self: *const Bulk) u16 {
        const ready: u16 = if (self.brdy != 0) regs.int0.brdy else 0;
        const empty: u16 = if (self.bemp != 0) regs.int0.bemp else 0;
        return ready | empty;
    }

    pub fn refusals(self: *const Bulk) u32 {
        return self.bad_pipe + self.not_ready + self.overdrain + self.oversize + self.overrun;
    }
};

/// The pipe bit in BRDYSTS and BEMPSTS.
pub fn bit(n: u4) u16 {
    return @as(u16, 1) << n;
}

/// Pipe n when it is in range and the driver opened it.
pub fn opened(pipes: *const pipe.Pipes, n: u4) ?pipe.Pipe {
    if (n == 0 or n > count) return null;
    const p = pipes.pipes[n - 1];
    if (p.kind() == .none) return null;
    return p;
}
