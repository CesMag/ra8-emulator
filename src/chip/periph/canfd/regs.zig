//! Where the CAN-FD registers sit and what their bits mean.
//!
//! Split out of canfd.zig the way eth/regs.zig sits beside eth.zig: the block
//! file is about what the controller DOES, and the geometry, the offsets and
//! the field masks are a table that only grows. canfd.zig re-exports every
//! name here, so a caller that only knows the block still reaches them
//! through it.
const std = @import("std");
const Bounded = @import("../../core/bounded.zig").Bounded;

/// CANFD geometry. The Non-secure alias is folded onto these by the bus.
pub const unit0_base: u32 = 0x4038_0000;
pub const unit1_base: u32 = 0x4038_2000;
pub const win_span: u32 = 0x1920;
pub const unit_count: usize = 2;

/// The registers this model interprets. Everything else is shadow.
pub const off_cnctr: u32 = 0x004;
pub const off_cnsts: u32 = 0x008;
pub const off_gctr: u32 = 0x018;
pub const off_gsts: u32 = 0x01C;
pub const off_rfsts0: u32 = 0x044;
pub const off_rfpctr0: u32 = 0x04C;
pub const off_tmc0: u32 = 0x070;
pub const off_tmsts0: u32 = 0x074;
pub const off_afl: u32 = 0x120;
pub const off_rf0: u32 = 0x520;
pub const off_tm0: u32 = 0x604;

/// The acceptance-filter page this model reads: sixteen entries of
/// {ID, mask, page 0, page 1}, as dev reads them.
pub const afl = struct {
    pub const stride: u32 = 0x10;
    pub const count: usize = 16;
};

/// The status and control bits dev's own masks name.
pub const field = struct {
    /// CFDGSTS.GRSTSTS, global reset status.
    pub const grststs: u32 = 1 << 0;
    /// CFDGSTS.GHLTSTS, global halt status.
    pub const ghltsts: u32 = 1 << 1;
    /// CFDGSTS.GRAMINIT, message-RAM init in progress. Clear from power-up
    /// here as on dev: there is no RAM to initialise.
    pub const graminit: u32 = 1 << 3;
    /// CFDC.STS.CRSTSTS, channel reset status.
    pub const crststs: u32 = 1 << 0;
    /// CFDC.STS.CHLTSTS, channel halt status.
    pub const chltsts: u32 = 1 << 1;
    /// CFDRFSTS.RFEMP, the FIFO is empty.
    pub const rfemp: u32 = 1 << 0;
    /// CFDRFSTS.RFIF, a frame is waiting.
    pub const rfif: u32 = 1 << 3;
    /// CFDTMC.TMTR, the transmit request.
    pub const tmtr: u32 = 1 << 0;
    /// CFDTMSTS.TMTRF = 10b, transmission complete.
    pub const tmtrf_done: u32 = 0x04;
    /// GMDC / CHMDC, the two-bit mode field both control registers carry.
    pub const mode: u32 = 0x3;
};

/// The CANFD0 RX-FIFO event, carried over from dev at its own best-effort
/// value: no FSP bsp_elc.h is installed here to check it against. Nothing in
/// this tree routes it, so it costs a polled image nothing and gives an
/// interrupt-driven one something to take.
pub const event = struct {
    pub const can0_rxf: u16 = 0x33D;
};

/// One event per boundary: the line is pending in the controller until the
/// firmware clears it, so re-raising every stage would say nothing new.
pub const Due = Bounded(u16, 1);

/// The three states both machines walk. A reserved encoding lands on
/// operation, which is what dev's else branch does.
pub const Mode = enum {
    operation,
    reset,
    halt,

    pub fn fromBits(value: u32) Mode {
        return switch (value & field.mode) {
            1 => .reset,
            2 => .halt,
            else => .operation,
        };
    }
};
