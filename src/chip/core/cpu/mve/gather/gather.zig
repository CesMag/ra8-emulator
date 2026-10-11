//! MVE gather loads and scatter stores with a vector of offsets, VLDRB/
//! VLDRH/VLDRW [Rn, Qm] and VSTRB/VSTRH/VSTRW [Rn, Qm] (RA8EMU-25), from
//! their pseudocode in the Arm ARM (DDI0553). Element e of Qm, read
//! unsigned at the register width, offsets Rn for element e; with
//! `uxtw #n` (os) it is first scaled by the memory size. Memory widths
//! narrower than the element sign- or zero-extend on load and truncate on
//! store through contiguous.element. The 64-bit VLDRD/VSTRD forms move
//! each doubleword as two word beats addressed by `beatAddress`.
const qreg = @import("../qreg.zig");
pub const imm_vectors = @import("imm_vectors.zig");
pub const vectors = @import("vectors.zig");
const Size = qreg.Size;

pub const Form = struct { msize: Size, esize: Size, signed: bool, store: bool, os: bool };

/// Whether the encoding names an access the architecture defines:
/// memory no wider than the element, os never with bytes, and a signed
/// load only when it widens. Stores are unsigned.
pub fn valid(f: Form) bool {
    const m = @backingInt(f.msize);
    const e = @backingInt(f.esize);
    if (m > e) return false;
    if (f.os and f.msize == .byte) return false;
    if (f.signed) return !f.store and m < e;
    return true;
}

pub const Address = struct { base: u32, offset: u32, msize: Size, os: bool };

/// The address element e touches: Rn plus its offset, scaled when os.
pub fn address(a: Address) u32 {
    const shift: u5 = if (a.os) @backingInt(a.msize) else 0;
    return a.base +% (a.offset << shift);
}

/// One 32-bit beat of a 64-bit VLDRD/VSTRD gather or scatter: the even
/// word of the doubleword's Qm pair offsets both beats, scaled by 8 under
/// uxtw #3, and the odd beat sits four bytes above the even one.
pub const Beat = struct { base: u32, offset: u32, os: bool, odd: bool };

pub fn beatAddress(b: Beat) u32 {
    const shift: u5 = if (b.os) 3 else 0;
    const high: u32 = if (b.odd) 4 else 0;
    return b.base +% (b.offset << shift) +% high;
}

/// The vector-base forms, VLDRW/VLDRD/VSTRW/VSTRD [Qm, #imm]{!}: each
/// element (or the even word of each doubleword) of Qm is a base address
/// moved by imm7 scaled by 4 or 8. With writeback that address replaces
/// the Qm element whatever the predicate says.
pub const VectorBase = struct { element: u32, imm7: u7, add: bool, double: bool };

pub fn vectorAddress(v: VectorBase) u32 {
    const offset: u32 = @as(u32, v.imm7) << if (v.double) 3 else 2;
    return if (v.add) v.element +% offset else v.element -% offset;
}
