//! The RIIC register file and the bits in it, as one place to name them.
//!
//! Every RIIC register is a byte (HUM Ch 39.2). The controller, the target
//! responder and the tests all read the same names from here rather than each
//! carrying its own copy.

/// Three channels at 0x4025_E000, 0x100 apart (HUM Ch 39.2). The board's
/// system I2C bus, where the port expander and the camera live, is channel 1
/// (P512 SCL1 / P511 SDA1).
pub const win_base: u32 = 0x4025_E000;
pub const channel_stride: u32 = 0x100;
pub const channel_count: usize = 3;
pub const win_span: u32 = channel_stride * @as(u32, channel_count);
pub const line_channel: usize = 1;

/// The registers the model interprets; the rest of a channel's window
/// reflects what was written to it.
pub const reg = struct {
    pub const iccr1: u32 = 0x00;
    pub const iccr2: u32 = 0x01;
    pub const icmr1: u32 = 0x02;
    pub const icmr3: u32 = 0x04;
    pub const icfer: u32 = 0x05;
    pub const icser: u32 = 0x06;
    pub const icsr1: u32 = 0x08;
    pub const icsr2: u32 = 0x09;
    pub const sarl0: u32 = 0x0A;
    pub const sarl1: u32 = 0x0C;
    pub const sarl2: u32 = 0x0E;
    pub const icbrl: u32 = 0x10;
    pub const icbrh: u32 = 0x11;
    pub const icdrt: u32 = 0x12;
    pub const icdrr: u32 = 0x13;
    /// Bytes of a channel window this model shadows.
    pub const count: u32 = 0x16;
};

/// ICCR1: the interface enable and the internal reset that hold the whole
/// block (HUM Ch 39.2.1).
pub const iccr1 = struct {
    pub const iicrst: u8 = 0x40;
    pub const ice: u8 = 0x80;
};

/// ICCR2: the condition requests and the bus-busy flag (HUM Ch 39.2.2).
pub const iccr2 = struct {
    pub const st: u8 = 0x02;
    pub const rs: u8 = 0x04;
    pub const sp: u8 = 0x08;
    pub const trs: u8 = 0x20;
    pub const mst: u8 = 0x40;
    pub const bbsy: u8 = 0x80;
};

/// ICMR3: the bus mode bits, of which only ACKBT is write-protected
/// (HUM Ch 39.2.5, p 2376).
pub const icmr3 = struct {
    pub const ackbr: u8 = 0x04;
    pub const ackbt: u8 = 0x08;
    pub const ackwp: u8 = 0x10;
    pub const rdrfs: u8 = 0x20;
    pub const wait: u8 = 0x40;
    pub const smbs: u8 = 0x80;
};

/// ICSR2: the status flags the polling driver waits on (HUM Ch 39.2.9).
pub const icsr2 = struct {
    pub const tmof: u8 = 0x01;
    pub const al: u8 = 0x02;
    pub const start: u8 = 0x04;
    pub const stop: u8 = 0x08;
    pub const nackf: u8 = 0x10;
    pub const rdrf: u8 = 0x20;
    pub const tend: u8 = 0x40;
    pub const tdre: u8 = 0x80;
};

/// ICSR1: the own-address match flags (HUM Ch 39.2.8).
pub const icsr1 = struct {
    pub const aas0: u8 = 0x01;
};

/// ICSER: which own-address slots answer (HUM Ch 39.2.7).
pub const icser = struct {
    pub const sar0e: u8 = 0x01;
    pub const sar1e: u8 = 0x02;
    pub const sar2e: u8 = 0x04;
    pub const slots: u8 = sar0e | sar1e | sar2e;
};
