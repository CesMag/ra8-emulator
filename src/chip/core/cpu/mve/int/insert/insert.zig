//! MVE shift-and-insert from the Arm ARM (DDI0553) pseudocode (RA8EMU-25).
//! VSRI shifts each lane of Qm right by n and inserts it into Qd under a
//! mask of the bits the shift filled, so the top n bits of each Qd lane
//! survive. VSLI is the same leftwards, so the bottom n bits survive.
const qreg = @import("../../qreg.zig");
pub const vectors = @import("vectors.zig");
const Size = qreg.Size;

fn full(size: Size) u64 {
    return (@as(u64, 1) << @intCast(qreg.bits(size))) - 1;
}

/// The lane-wise insert of `shifted` into `d` under `mask`.
fn insert(d: u128, m: u128, size: Size, mask: u64, right: bool, n: u6) u128 {
    var out: u128 = 0;
    for (0..qreg.lanes(size)) |k| {
        const e: u8 = @intCast(k);
        const x: u64 = qreg.elem(d, size, e);
        const y: u64 = qreg.elem(m, size, e);
        const moved = if (right) y >> n else (y << n) & full(size);
        out = qreg.setElem(out, size, e, @truncate((x & ~mask) | (moved & mask)));
    }
    return out;
}

/// VSRI with a shift of 1 to the lane width.
pub fn sri(d: u128, m: u128, size: Size, n: u6) u128 {
    return insert(d, m, size, full(size) >> n, true, n);
}

/// VSLI with a shift of 0 to one less than the lane width.
pub fn sli(d: u128, m: u128, size: Size, n: u6) u128 {
    return insert(d, m, size, (full(size) << n) & full(size), false, n);
}
