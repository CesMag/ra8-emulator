//! Whether a store to DODIR carries a whole operand.
//!
//! DODIR is the DOC's data input: one store is one operation, and the operand
//! goes in whole. DOCR.DOBW says how wide that operand is, 16 bits clear and
//! 32 bits set, and the register itself occupies the word at +0x0C either way
//! (ra8_doc_regs.h names it "Data input (access width per DOBW)").
//!
//! So an access that cannot carry the operand is not a partial operand, it is
//! no operand at all. The unit has one input latch, not four addressable
//! lanes: there is nowhere for half an operand to wait for the other half,
//! and running the operation on the lanes the access named would put a result
//! in DODSR0 that the firmware never asked for.
//!
//! WIDER IS STILL FINE, and that matters: ra8_doc.c writes a 16-bit operand
//! through `(volatile uint16_t*)&reg->DODIR` with DOBW clear, and zeroes the
//! register with a plain 32-bit `reg->DODIR = 0U` at deinit. Both start at
//! lane 0 and both are at least as wide as the operand, so both carry.
//!
//! WHAT THIS FILE DOES NOT CLAIM: what silicon does with the refused store.
//! No page in either tree says whether the DOC latches a partial write,
//! ignores it, or runs on it, so the model does not invent an answer. It
//! declines to run an operation it cannot build honestly and counts the
//! store, which is the same cut SPDR, RDAT, SSIFTDR and MENTRYR already make
//! for their own data ports in this tree.

/// The operand widths DOCR.DOBW selects, in bytes.
pub const bytes = struct {
    /// DOBW clear: the 16-bit unit, and what every in-tree helper programs.
    pub const narrow: u32 = 2;
    /// DOBW set: the 32-bit unit.
    pub const wide: u32 = 4;
};

/// How many bytes of operand the unit is waiting for.
pub fn operandBytes(wide: bool) u32 {
    return if (wide) bytes.wide else bytes.narrow;
}

/// Does an access starting `lane` bytes into DODIR and `width` bytes wide
/// carry a whole operand? It has to start at the bottom of the register and
/// be at least as wide as the operand; anything else names part of it.
pub fn carriedBy(lane: u32, width: u3, wide: bool) bool {
    return lane == 0 and @as(u32, width) >= operandBytes(wide);
}
