//! The I3C channel's register file in legacy I2C mode, as one place to name
//! it.
//!
//! The RA8D2 has one I3C channel at 0x4035_F000. Driven with PRTS.PRTMD set
//! it is an ordinary I2C controller (IIC_B), which is how the touch driver
//! reaches the panel on the carrier. The controller, the responder half and
//! the tests all read these names from here rather than each carrying a copy.

/// One channel, 0x214 wide: through BCST at +0x210.
pub const win_base: u32 = 0x4035_F000;
pub const win_span: u32 = 0x214;

/// The registers the model interprets; the rest of the window reflects what
/// was written to it, so "configure then verify" still works.
pub const reg = struct {
    /// Own device address: the firmware claiming one is the firmware coming
    /// up as an addressed target.
    pub const msdvad: u32 = 0x018;
    /// Condition request: START, repeated START, STOP.
    pub const cndctl: u32 = 0x140;
    /// The transfer data buffer port, both directions.
    pub const ntdtbp0: u32 = 0x158;
    /// Bus status, write-0-to-clear.
    pub const bst: u32 = 0x1D0;
    /// Normal-transfer status: which way the buffer is ready.
    pub const ntst: u32 = 0x1E0;
    /// Bus condition status, where the bus-free flag lives.
    pub const bcst: u32 = 0x210;
    /// Words of the window this model shadows.
    pub const words: usize = win_span / 4;
};

/// CNDCTL: the three condition requests.
pub const cndctl = struct {
    pub const stcnd: u32 = 0x0000_0001;
    pub const srcnd: u32 = 0x0000_0002;
    pub const spcnd: u32 = 0x0000_0004;
};

/// BST: what the bus did. Every bit here is write-0-to-clear.
pub const bst = struct {
    pub const stcnddf: u32 = 0x0000_0001;
    pub const spcnddf: u32 = 0x0000_0002;
    pub const nackdf: u32 = 0x0000_0010;
    pub const tendf: u32 = 0x0000_0100;
    pub const alf: u32 = 0x0001_0000;
    pub const todf: u32 = 0x0010_0000;
};

/// NTST: which side of the data buffer is ready.
pub const ntst = struct {
    pub const tdbef0: u32 = 0x0000_0001;
    pub const rdbff0: u32 = 0x0000_0002;
};

/// BCST: the bus-free flag a driver gates a new transaction on.
pub const bcst = struct {
    pub const bfref: u32 = 0x0000_0001;
};
