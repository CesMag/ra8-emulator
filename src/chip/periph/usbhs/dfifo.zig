//! The two data FIFO ports, D0FIFO and D1FIFO: which pipe each is aimed at,
//! how wide an access each answers, and which way its pipe runs.
//!
//! dev did not model these at all. Every offset in the pair fell through to
//! the register shadow, so a driver that moved bulk payload the way the
//! hardware manual says to move it wrote its packet into a shadow word and
//! read the same word back as the packet the device had answered with. The
//! transfer looked perfect and nothing ever reached the far end.
//!
//! A data port is not CFIFO at a different offset. There is no ISEL here: the
//! direction is the one PIPECFG gave the pipe. MBW says how wide an access the
//! port answers, and the DCP is not reachable from one at all.
const regs = @import("regs.zig");

/// One data port's aim.
pub const DataPort = struct {
    /// DnFIFOSEL as written, minus a CURPIPE that named nothing.
    sel: u16 = 0,
    /// True once a pipe in range has been selected.
    aimed: bool = false,

    /// Accesses refused, each for its own reason.
    bad_pipe: u32 = 0,
    contended: u32 = 0,
    bad_width: u32 = 0,
    wrong_way: u32 = 0,

    pub fn pipe(self: *const DataPort) ?u32 {
        if (!self.aimed) return null;
        return self.sel & regs.fifo.curpipe_mask;
    }

    /// DCLRM: the port throws the buffer away itself once a short packet has
    /// been drained, rather than waiting for a BCLR.
    pub fn autoClears(self: *const DataPort) bool {
        return self.sel & regs.dfifo.dclrm != 0;
    }

    /// The access width MBW asks for, in bytes. An MBW the part does not
    /// have leaves the port answering nothing.
    pub fn width(self: *const DataPort) ?u3 {
        return regs.dfifo.accessWidth(self.sel);
    }

    pub fn refusals(self: *const DataPort) u32 {
        return self.bad_pipe + self.contended +
            self.bad_width + self.wrong_way;
    }
};

/// The pair, and the arbitration between them. Two ports aimed at one pipe is
/// the case that needs an owner, so the pair owns it.
pub const Ports = struct {
    ports: [regs.dfifo.count]DataPort = @splat(.{}),

    /// DnFIFOSEL. CURPIPE 0 parks the port: it is the reset value, and the
    /// way a driver lets go of a data port when it resets the controller.
    /// The DCP answers on CFIFO only, so a parked port reaches no pipe, but
    /// parking is not a refusal. Two aims are: a pipe the part does not have,
    /// and a pipe the other data port or CFIFO already holds.
    pub fn select(self: *Ports, which: u32, value: u16, taken_by_cfifo: ?u32) void {
        const port = &self.ports[which];
        const aimed_at = value & regs.fifo.curpipe_mask;
        port.sel = value & ~regs.fifo.curpipe_mask;
        port.aimed = false;
        if (aimed_at >= regs.pipe.count) {
            port.bad_pipe += 1;
            return;
        }
        if (aimed_at == 0) return;
        if (self.heldElsewhere(which, aimed_at) or taken_by_cfifo == aimed_at) {
            port.contended += 1;
            return;
        }
        port.sel = value;
        port.aimed = true;
    }

    /// True when the other data port is already aimed at this pipe.
    fn heldElsewhere(self: *const Ports, which: u32, aimed_at: u16) bool {
        var other: u32 = 0;
        while (other < self.ports.len) : (other += 1) {
            if (other == which) continue;
            const held = self.ports[other].pipe() orelse continue;
            if (held == aimed_at) return true;
        }
        return false;
    }

    /// Whether an access of this width is the one MBW asked for. dev had no
    /// data port to get this wrong on, but the hardware does: a 32-bit store
    /// into a port programmed for byte access does not put four bytes on the
    /// wire, it faults the transfer.
    pub fn accepts(self: *Ports, which: u32, access: u3) bool {
        const port = &self.ports[which];
        const want = port.width() orelse {
            port.bad_width += 1;
            return false;
        };
        if (want != access) {
            port.bad_width += 1;
            return false;
        }
        return true;
    }

    /// A data port runs the direction its pipe was configured for, so a read
    /// of an OUT pipe and a write of an IN pipe are both refused. CFIFO has
    /// an ISEL bit for this; DnFIFOSEL has none, and a model that reuses it
    /// lets a driver read back the packet it just wrote.
    pub fn runs(self: *Ports, which: u32, pipe_is_in: bool, reading: bool) bool {
        const port = &self.ports[which];
        if (pipe_is_in == reading) return true;
        port.wrong_way += 1;
        return false;
    }

    /// A bus reset lets go of both aims. What was refused before it stays
    /// counted: the reset is the device's state going away, not the model's
    /// accounting of what the driver asked for.
    pub fn release(self: *Ports) void {
        for (&self.ports) |*port| {
            port.sel = 0;
            port.aimed = false;
        }
    }

    pub fn refusals(self: *const Ports) u32 {
        var total: u32 = 0;
        for (&self.ports) |port| total += port.refusals();
        return total;
    }

    pub fn quiet(self: *const Ports) bool {
        if (self.refusals() != 0) return false;
        for (&self.ports) |port| {
            if (port.sel != 0) return false;
        }
        return true;
    }
};

/// Which of the two ports an offset names, for the four offsets that are a
/// data port's own: the data register, the selector and the control register.
pub fn portOf(offset: u32) ?u32 {
    return switch (offset) {
        regs.reg.d0fifo,
        regs.reg.d0fifo + regs.window.word,
        regs.reg.d0fifosel,
        regs.reg.d0fifoctr,
        => 0,
        regs.reg.d1fifo,
        regs.reg.d1fifo + regs.window.word,
        regs.reg.d1fifosel,
        regs.reg.d1fifoctr,
        => 1,
        else => null,
    };
}

/// True when the offset is a data port's data register, including the upper
/// half a 32-bit access reaches through.
pub fn isData(offset: u32) bool {
    return offset == regs.reg.d0fifo or offset == regs.reg.d0fifo + regs.window.word or
        offset == regs.reg.d1fifo or offset == regs.reg.d1fifo + regs.window.word;
}

pub fn isControl(offset: u32) bool {
    return offset == regs.reg.d0fifoctr or offset == regs.reg.d1fifoctr;
}
