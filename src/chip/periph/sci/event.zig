//! The ELC event numbers the console channel raises (HUM Ch 19 Table 19.3,
//! FSP `bsp_elc.h` for ra8d2: SCI8_RXI 0x122, _TXI 0x123, _TEI 0x124). A
//! firmware that routes one of these writes the same number into an IELSR
//! slot, and src/chip/periph/icu/icu.zig matches the raised event to that slot.
//!
//! Only the console channel has modelled event numbers, the same limit dev
//! draws: the other nine channels raise nothing until something needs them.
pub const rxi: u16 = 0x122;
pub const txi: u16 = 0x123;
pub const tei: u16 = 0x124;
