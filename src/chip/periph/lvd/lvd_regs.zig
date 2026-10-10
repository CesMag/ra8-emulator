//! The PVD register fields, and the Vdet each PVDLVL encoding selects.
//!
//! Its own file so src/chip/periph/lvd/lvd_field_lock.zig can name the two fields it
//! guards without reaching back into the block that owns the state, the way
//! canfd_regs.zig sits under canfd.zig. lvd.zig re-exports every name here,
//! so callers still reach them through the block.

/// Which of the two PVD flavours a channel is. An m channel has a status
/// register, an interrupt path, and the RI/RN reset bits; an n channel is
/// reset-only and has none of them, which is what makes several of the
/// interlocks below m-only.
pub const Series = enum { monitor, reset_only };

/// PVDmCMPCR (HUM Ch 8.2.2 p 303): PVDLVL[4:0] plus the PVDE enable.
pub const compare = struct {
    pub const level: u8 = 0x1F;
    pub const enable: u8 = 0x80;
};

/// PVDmCR0 (HUM Ch 8.2.4 p 305) and PVDnCR0 (Ch 8.2.5 p 306). Bit 3 on an m
/// channel and bit 6 on an n channel are the reserved read-as-1 markers.
pub const control = struct {
    pub const rie: u8 = 0x01;
    pub const dfdis: u8 = 0x02;
    pub const cmpe: u8 = 0x04;
    pub const m_marker: u8 = 0x08;
    pub const fsamp: u8 = 0x30;
    pub const ri: u8 = 0x40;
    pub const n_marker: u8 = 0x40;
    pub const rn: u8 = 0x80;
};

/// PVDmCR1 (HUM Ch 8.2.6 p 307): the edge selector and the NMI/IRQ choice.
pub const irq = struct {
    pub const idtsel: u8 = 0x03;
    pub const irqsel: u8 = 0x04;
    pub const writable: u8 = idtsel | irqsel;
};

/// PVDmSR (HUM Ch 8.2.7 p 307). DET is write-0-to-clear, MON is read-only.
pub const status = struct {
    pub const det: u8 = 0x01;
    pub const mon: u8 = 0x02;
};

/// PVDmFCR (HUM Ch 8.2.8 p 308): RHSEL is the only writable bit.
pub const hysteresis = struct {
    pub const rhsel: u8 = 0x01;
};

/// PVDLR (HUM Ch 8.2.10 p 309): LOCK resets to 1 and gates the n channels.
pub const lock = struct {
    pub const bit: u8 = 0x01;
};

/// PVDmCR1.IDTSEL: which crossing latches DET. 11b is prohibited.
pub const Edge = enum(u2) { rise = 0, fall = 1, both = 2, prohibited = 3 };

/// The PVDLVL encodings HUM Ch 8.2.2 Table 8.2 p 303 allows, and the nominal
/// Vdet each one selects. Anything outside 0x03..0x0F is reserved.
pub const level_min: u8 = 0x03;
pub const level_max: u8 = 0x0F;
pub const detect_millivolts = [_]u16{
    3860, 3140, 3100, 3080, 2850, 2830, 2800, 2620, 2330, 1900, 1860, 1740, 1710,
};

/// The threshold a PVDLVL encoding selects, or null when it is reserved.
pub fn detectVoltage(bits: u8) ?u16 {
    const level = bits & compare.level;
    if (level < level_min or level > level_max) return null;
    return detect_millivolts[level - level_min];
}
