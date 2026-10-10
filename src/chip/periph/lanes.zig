//! Byte lanes of a 32-bit peripheral register window.
//!
//! An access on this bus carries an address and a width, and a peripheral has
//! to answer the register the address lands in cut to the lanes the width
//! names. Three blocks now need the same arithmetic (`src/chip/periph/gpio/gpio_regs.zig`
//! for the PORT halves, `src/chip/periph/sci/sci.zig` for the status words, and
//! `src/chip/periph/elc/elc_regs.zig` for the event links), so it lives in one place
//! rather than in three.
//!
//! The rule the callers share: A READ IS SERVED FROM THE WORD THE ACCESS LANDS
//! IN AND THEN CUT, AND A NARROW STORE IS MERGED INTO THAT WORD SO THE LANES
//! IT DOES NOT NAME KEEP THE VALUE THEY HAD. Anything a register does beyond
//! that (a read-only word, a strobe that does not read back, a lane that is
//! reserved) belongs to the block, not here.

/// The word an offset lands in.
pub fn word(offset: u32) u32 {
    return offset & ~@as(u32, 3);
}

/// Which byte of that word the access starts at.
pub fn lane(offset: u32) u32 {
    return offset % 4;
}

/// The bits of the word an access of `width` starting at byte `at` names.
pub fn named(at: u32, width: u3) u32 {
    if (width >= 4) return ~@as(u32, 0);
    const shift: u5 = @intCast(at * 8);
    const bits: u32 = if (width == 1) 0xFF else 0xFFFF;
    return bits << shift;
}

/// The part of a 32-bit register a narrow access names.
pub fn part(value: u32, at: u32, width: u3) u32 {
    if (width >= 4) return value;
    const shift: u5 = @intCast(at * 8);
    const shifted = value >> shift;
    return if (width == 1) shifted & 0xFF else shifted & 0xFFFF;
}

/// Fold a narrow store into a 32-bit register, leaving the bytes the access
/// does not name exactly where they were.
pub fn merge(current: u32, at: u32, width: u3, value: u32) u32 {
    if (width >= 4) return value;
    const shift: u5 = @intCast(at * 8);
    const bits: u32 = if (width == 1) 0xFF else 0xFFFF;
    const window: u32 = bits << shift;
    return (current & ~window) | ((value & bits) << shift);
}
