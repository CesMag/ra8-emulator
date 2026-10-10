//! The SSIE transmit staging FIFO: how many samples it holds, what SSIFSR
//! reports about that, and what a reset does to it.
//!
//! Split out of src/chip/periph/ssie/ssie.zig, which models the handshake and the
//! sample stream. This file owns the part a driver uses for flow control.
//!
//! THE DEPTH IS THE PART'S, NOT A NUMBER THIS MODEL PICKED. ra8_ssie_regs.h
//! on ra8-firmware's zig/dev carries `k_ra8_ssie_fifo_depth = 32`, a 32-stage
//! FIFO per direction (HUM Ch 46.2.4 p 3083). The old model staged eight and
//! said so in its own header, so a driver priming a full FIFO lost three
//! quarters of what it wrote.
//!
//! SSIFSR CARRIES THE COUNT, NOT JUST THE EMPTY FLAG. TDC[5:0] sits at bits
//! 29..24 and RDC[5:0] at 13..8 (ra8_ssie_regs.h k_ra8_ssie_mask_tdc /
//! k_ra8_ssie_shift_tdc). That field is what `ra8_ssie_write_buffer` reads
//! before every store: it breaks out of its loop the moment TDC reaches the
//! depth, so a model answering a flat zero tells the driver there is room
//! forever and the samples past the last stage go on the floor while the
//! driver reports them written.
//!
//! A RESET EMPTIES IT. SSIFCR's RFRST (bit 0) and TFRST (bit 1) are the FIFO
//! resets (HUM Ch 46.2.3 p 3077). `internal_pulse_fifo_reset` in ra8_ssie.c
//! asserts both and clears them again on every start, so a channel restarted
//! after a reconfiguration begins with an empty FIFO rather than draining
//! samples staged for the setup it just replaced.
//!
//! NOT MODELLED, AND NOT GUESSED: holding a reset bit asserted. Neither tree
//! says whether a FIFO stays clamped while RFRST or TFRST reads 1, and the
//! driver only ever pulses them, so the flush happens on the write that
//! asserts the bit and the bit is then just a bit. Nor are the bits
//! self-clearing here: the driver writes them back to zero itself, and
//! nothing in either tree says the hardware would have.
//!
//! NOT MODELLED EITHER: RDC. There is no receive source in this model, so the
//! count is always zero; the field is named here so the read path packs it in
//! the right place when one arrives, not because a value is being invented.
const std = @import("std");

/// Stages per direction (ra8_ssie_regs.h k_ra8_ssie_fifo_depth).
pub const depth = struct {
    pub const stages: usize = 32;
};

/// SSIFSR fields (HUM Ch 46.2.4 p 3083).
pub const status = struct {
    pub const rdf: u32 = 0x0000_0001;
    pub const rdc_mask: u32 = 0x0000_3F00;
    pub const rdc_shift: u5 = 8;
    pub const tde: u32 = 0x0001_0000;
    pub const tdc_mask: u32 = 0x3F00_0000;
    pub const tdc_shift: u5 = 24;
};

/// SSIFCR's FIFO resets (HUM Ch 46.2.3 p 3077).
pub const reset = struct {
    pub const receive: u32 = 0x0000_0001;
    pub const transmit: u32 = 0x0000_0002;
    pub const both: u32 = receive | transmit;
};

/// The samples a channel is holding, oldest first, plus what the run should
/// be told about the ones it could not hold.
pub const Stage = struct {
    samples: [depth.stages]u32 = @splat(0),
    held: usize = 0,
    /// Stores that arrived with every stage full.
    overruns: u32 = 0,
    /// Samples a TFRST threw away before they were ever shifted out.
    discarded: u32 = 0,

    pub fn quiet(self: *const Stage) bool {
        return self.held == 0 and self.overruns == 0 and self.discarded == 0;
    }

    pub fn empty(self: *const Stage) bool {
        return self.held == 0;
    }

    pub fn full(self: *const Stage) bool {
        return self.held >= depth.stages;
    }

    /// Stage one sample. False means the FIFO was full and the store is gone,
    /// which is the overrun a driver reading TDC would have avoided.
    pub fn push(self: *Stage, sample: u32) bool {
        if (self.full()) {
            self.overruns +%= 1;
            return false;
        }
        self.samples[self.held] = sample;
        self.held += 1;
        return true;
    }

    /// What is waiting, oldest first.
    pub fn pending(self: *const Stage) []const u32 {
        return self.samples[0..self.held];
    }

    /// Empty it because the samples went somewhere: a drain, not a loss.
    pub fn clear(self: *Stage) void {
        self.held = 0;
    }

    /// Empty it because TFRST said so. Whatever was waiting is lost, and that
    /// is worth counting: it is a stream the firmware thought it had queued.
    pub fn flush(self: *Stage) void {
        self.discarded +%= @intCast(self.held);
        self.held = 0;
    }
};

/// The stage count packed where SSIFSR.TDC reports it. The field is six bits
/// and the FIFO is 32 stages deep, so a full FIFO reads 32 and nothing can
/// overflow the field.
pub fn transmitCount(held: usize) u32 {
    const capped: u32 = @intCast(@min(held, depth.stages));
    return (capped << status.tdc_shift) & status.tdc_mask;
}

/// The same for the receive side, so the read path has one place to change
/// when a receive source lands.
pub fn receiveCount(held: usize) u32 {
    const capped: u32 = @intCast(@min(held, depth.stages));
    return (capped << status.rdc_shift) & status.rdc_mask;
}

/// The reset bits a write asserts that were not already set. Only a rising
/// edge flushes, so a driver leaving a bit set does not re-empty the FIFO on
/// every later store to SSIFCR.
pub fn asserted(before: u32, after: u32) u32 {
    return after & ~before & reset.both;
}
