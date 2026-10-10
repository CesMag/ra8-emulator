//! The CSD v2.0 register, as far as the capacity field the card model fills.
pub const length: usize = 16;
/// CSD_STRUCTURE = 01b, a v2.0 (high capacity) card.
pub const version: u8 = 0x40;
/// C_SIZE spans bytes 7..9, six bits wide in the first of them.
pub const csize_high: usize = 7;
pub const csize_mid: usize = 8;
pub const csize_low: usize = 9;
pub const high_mask: u32 = 0x3F;
