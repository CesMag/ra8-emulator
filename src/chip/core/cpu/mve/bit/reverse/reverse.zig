//! MVE VBRSR, bit reverse and shift right (RA8EMU-25), from its pseudocode
//! in the Arm ARM (DDI0553): every lane's bits are reversed and the low
//! Rm[7:0] bits of the reversal are kept, all of it when Rm[7:0] reaches
//! the element width and none of it when Rm[7:0] is zero.
const qreg = @import("../../qreg.zig");
pub const vectors = @import("vectors.zig");
const Size = qreg.Size;

/// One element: `e` bit-reversed within `width` bits, keeping `keep` bits.
pub fn element(e: u32, width: u6, keep: u8) u32 {
    if (keep == 0) return 0;
    const reversed = @bitReverse(e) >> @intCast(32 - @as(u7, width));
    if (keep >= width) return reversed;
    return reversed >> @intCast(width - keep);
}

/// Every lane of `a` through `element`, with the bit count from `rm`.
pub fn reverseShift(a: u128, rm: u32, size: Size) u128 {
    const width: u6 = @intCast(qreg.bits(size));
    const keep: u8 = @truncate(rm);
    var out: u128 = 0;
    for (0..qreg.lanes(size)) |k| {
        const lane: u8 = @intCast(k);
        out = qreg.setElem(out, size, lane, element(qreg.elem(a, size, lane), width, keep));
    }
    return out;
}
