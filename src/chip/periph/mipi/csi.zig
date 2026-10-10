//! MIPI CSI-2 receiver: the camera side of the D-PHY, so its short-packet
//! clear can finish.
//!
//! One window at 0x4034_7000 (ra8_glcdc_regs.h, k_ra8_mipi_csi_base_addr,
//! above the D-PHY at 0x4034_6C00 this block sits on). Nothing modelled it,
//! so every access fell through to the sparse register file, and that had
//! teeth in one place: GSST is read-only status the firmware never writes,
//! so the sparse file answered zero forever.
//! ra8_mipi_csi_short_packet_clear_fifo drives GSIU.GFCLR and then spins on
//! GSST.GCD for k_ra8_mipi_csi_gfclr_spin_max = 1024 polls; against zero it
//! burned the whole budget and returned a hardware timeout on a part that
//! had cleared the FIFO instantly. Same shape as the D-PHY's PWRSF and
//! PLLSF last slice: a flag that never rises.
//!
//! Second, quieter: MCG is a read-only module-configuration word carrying
//! the core version, the supported lane count and the FIFO depth.
//! ra8_mipi_csi_capabilities decodes it, and zero told the caller the part
//! supports no lanes and has no short-packet FIFO.
//!
//!   MCG   (+0x000)  module configuration, read-only, derived here
//!   MCT0  (+0x010)  lanes and receive modes
//!   MCT2  (+0x018)  clock rates
//!   MCT3  (+0x01C)  RXEN
//!   RTCT  (+0x028)  VSRST, the video-pixel software reset
//!   RTST  (+0x02C)  VSRSTS, read-only, derived here
//!   MIST  (+0x050)  module interrupt status
//!   RXST/RXSC/RXIE (+0x070..)  receive status, clear, enable
//!   DLST/DLSC/DLIE (+0x080..)  per data lane, stride 0x10, 2 lanes
//!   VCST/VCSC/VCIE (+0x100..)  per virtual channel, stride 0x10, 16 of them
//!   PMST/PMSC/PMIE (+0x200..)  power management
//!   GSCT  (+0x280)  short-packet control
//!   GSST  (+0x284)  short-packet status, read-only, derived here
//!   GSHT  (+0x290)  short-packet header, read-only
//!   GSIU  (+0x294)  short-packet information update
//!
//! NOT MODELLED, AND NOT GUESSED: reception itself. No sensor drives this
//! block here, so the packet queue is only ever empty, PNUM reads zero and
//! ra8_mipi_csi_read_short_packet honestly returns "empty" rather than a
//! header this file made up. The lane and virtual-channel status words are
//! error latches fed by a real link, so they stay a shadow the firmware
//! reads back what it wrote into; nothing in either tree says what a lane
//! reports when there is no lane. The reset is instantaneous, because
//! neither tree carries a drain time, so RTST.VSRSTS reads clear and the
//! init spin ends on its first poll.
const periph = @import("../registry.zig");
const short = @import("csi_short.zig");

/// Receiver geometry. The bus folds the Non-secure alias at 0x5034_7000
/// onto this base.
pub const win_base: u32 = 0x4034_7000;
/// k_ra8_mipi_csi_window_size, GSIU inclusive.
pub const win_span: u32 = 0x298;

/// The short-packet rule, re-exported so callers reach it through here.
pub const fifo = short;

pub const off = struct {
    pub const mcg: u32 = 0x000;
    pub const mct3: u32 = 0x01C;
    pub const rtct: u32 = 0x028;
    pub const rtst: u32 = 0x02C;
    pub const gsct: u32 = 0x280;
    pub const gsst: u32 = 0x284;
    pub const gsht: u32 = 0x290;
    pub const gsiu: u32 = 0x294;
};

/// MCG as this part reports itself: core version 1, SDLN 2 data lanes,
/// GSNM 16 FIFO stages, per ra8_mipi_csi_regs.h.
pub const capability = struct {
    pub const version: u32 = 1;
    pub const lanes: u32 = 2;
    pub const stages: u32 = short.depth;

    pub fn word() u32 {
        return (version & 0xF) | ((lanes & 0xF) << 8) | ((stages & 0xFF) << 16);
    }
};

/// MCT3.RXEN, the one writable bit in that register.
pub const receive = struct {
    pub const enable: u32 = 0x0000_0001;
};

/// RTCT.VSRST, write 1 to reset the video-pixel interface.
pub const reset_control = struct {
    pub const request: u32 = 0x0000_0001;
};

/// RTST.VSRSTS, set while a reset is draining.
pub const reset_status = struct {
    pub const busy: u32 = 0x0000_0001;
};

/// The receiver: the registers this model interprets, a shadow for the rest
/// of the window, and what the run should be told about it.
pub const MipiCsi = struct {
    gsct: u32 = 0,
    gsiu: u32 = 0,
    mct3: u32 = 0,
    /// Packets waiting to be read out. Nothing drives the link here, so this
    /// is only ever zero; it exists so GSST is derived from the queue rather
    /// than hard-coded to empty.
    queued: u32 = 0,
    /// GCD: a clear completed and GFCLR has not been released yet.
    cleared: bool = false,
    /// Every other word in the window.
    shadow: [win_span]u8 = @splat(0),
    /// Reads of GSST, which is how the driver waits out a clear.
    polls: u32 = 0,
    /// Stores aimed at a read-only word (MCG, RTST, GSST, GSHT).
    refused: u32 = 0,
    /// Completed FIFO clears.
    clears: u32 = 0,
    /// Read-pointer advances asked for with nothing queued.
    empty_advances: u32 = 0,
    /// Times storing was re-enabled after an overflow.
    reenables: u32 = 0,
    /// Video-pixel software resets.
    resets: u32 = 0,
    /// Times RXEN went from clear to set.
    enables: u32 = 0,
    /// Enables taken while short-packet storing was off, so a generic short
    /// packet arriving on the link would be dropped rather than queued.
    blind_enables: u32 = 0,

    pub fn init() MipiCsi {
        return .{};
    }

    pub fn quiet(self: *const MipiCsi) bool {
        return self.polls == 0 and self.refused == 0 and self.clears == 0 and
            self.resets == 0 and self.enables == 0;
    }

    pub fn receiving(self: *const MipiCsi) bool {
        return self.mct3 & receive.enable != 0;
    }

    pub fn storing(self: *const MipiCsi) bool {
        return short.storing(self.gsct);
    }

    /// GSST as it stands right now, without counting a read.
    pub fn gsst(self: *const MipiCsi) u32 {
        return short.value(self.queued, short.thresholdOf(self.gsct), self.cleared, self.storing());
    }

    /// A read of GSST, counted because it is the driver's wait.
    fn pollStatus(self: *MipiCsi) u32 {
        self.polls +%= 1;
        return self.gsst();
    }

    fn readWord(self: *MipiCsi, local: u32) u32 {
        return switch (local) {
            off.mcg => capability.word(),
            off.mct3 => self.mct3,
            // The reset is instantaneous here, so it is never busy.
            off.rtst => 0,
            off.gsct => self.gsct,
            off.gsst => self.pollStatus(),
            // Nothing is queued, so there is no header to hand back. The
            // driver only reads this after PNUM said a packet was waiting.
            off.gsht => 0,
            off.gsiu => self.gsiu,
            else => self.shadowWord(local),
        };
    }

    fn writeWord(self: *MipiCsi, local: u32, value: u32) void {
        switch (local) {
            // Read-only: the receiver owns these.
            off.mcg, off.rtst, off.gsst, off.gsht => self.refused +%= 1,
            off.mct3 => self.setReceive(value),
            off.rtct => self.setReset(value),
            off.gsct => self.gsct = value,
            off.gsiu => self.setUpdate(value),
            else => self.setShadowWord(local, value),
        }
    }

    fn setReceive(self: *MipiCsi, value: u32) void {
        const was_on = self.receiving();
        self.mct3 = value;
        if (!was_on and self.receiving()) {
            self.enables +%= 1;
            if (!self.storing()) self.blind_enables +%= 1;
        }
    }

    fn setReset(self: *MipiCsi, value: u32) void {
        if (value & reset_control.request == 0) return;
        self.resets +%= 1;
        self.queued = 0;
        self.cleared = false;
    }

    /// GSIU is three request lines, and the clear is the one with a
    /// handshake: GFCLR high empties the queue and raises GCD, and GCD
    /// falls again when the driver releases GFCLR, which is exactly the
    /// order ra8_mipi_csi_short_packet_clear_fifo drives.
    fn setUpdate(self: *MipiCsi, value: u32) void {
        self.gsiu = value;
        if (short.clearRequested(value)) {
            if (!self.cleared) {
                self.queued = 0;
                self.cleared = true;
                self.clears +%= 1;
            }
        } else {
            self.cleared = false;
        }
        if (short.advanceRequested(value)) {
            if (self.queued == 0) self.empty_advances +%= 1 else self.queued -= 1;
        }
        if (short.reenableRequested(value)) self.reenables +%= 1;
    }

    fn shadowWord(self: *const MipiCsi, local: u32) u32 {
        var value: u32 = 0;
        var index: u32 = 0;
        while (index < 4 and local + index < win_span) : (index += 1) {
            const shift: u5 = @intCast(index * 8);
            value |= @as(u32, self.shadow[local + index]) << shift;
        }
        return value;
    }

    fn setShadowWord(self: *MipiCsi, local: u32, value: u32) void {
        var index: u32 = 0;
        while (index < 4 and local + index < win_span) : (index += 1) {
            const shift: u5 = @intCast(index * 8);
            self.shadow[local + index] = @truncate(value >> shift);
        }
    }

    /// Every register here is a 32-bit word, so a narrower access is served
    /// out of the word it lands in rather than pretending the window is a
    /// byte array.
    pub fn read(self: *MipiCsi, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        if (offset >= win_span) return 0;
        const word = offset & ~@as(u32, 3);
        const shift: u5 = @intCast((offset & 3) * 8);
        const value = self.readWord(word) >> shift;
        return switch (width) {
            1 => value & 0xFF,
            2 => value & 0xFFFF,
            else => value,
        };
    }

    pub fn write(self: *MipiCsi, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        if (offset >= win_span) return;
        const word = offset & ~@as(u32, 3);
        if (width == 4 and offset == word) {
            self.writeWord(word, value);
            return;
        }
        const shift: u5 = @intCast((offset & 3) * 8);
        const mask: u32 = switch (width) {
            1 => @as(u32, 0xFF) << shift,
            2 => @as(u32, 0xFFFF) << shift,
            else => 0xFFFF_FFFF,
        };
        const merged = (self.readWordQuiet(word) & ~mask) | ((value << shift) & mask);
        self.writeWord(word, merged);
    }

    /// The same read the bus would do, without counting a GSST poll: a byte
    /// store into a word is not firmware waiting on the FIFO.
    fn readWordQuiet(self: *MipiCsi, local: u32) u32 {
        if (local == off.gsst) return self.gsst();
        return self.readWord(local);
    }

    pub fn block(self: *MipiCsi) periph.Block {
        return .{
            .name = "MIPI-CSI",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *MipiCsi = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *MipiCsi = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
