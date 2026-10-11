//! MVE integer compares from the Arm ARM (DDI0553) pseudocode for VCMP and
//! VPT (RA8EMU-25). Each element's result sets or clears every P0 bit of
//! the bytes it spans. EQ and NE compare the raw bits, CS and HI compare
//! unsigned, and GE, LT, GT and LE compare signed.
const qreg = @import("../qreg.zig");
const int = @import("../int/int.zig");
pub const vectors = @import("vectors.zig");
const Size = qreg.Size;

/// The condition, numbered as the encoding builds it: signed (hw2 bit 12),
/// then fc[0], then fc[1] (hw2 bit 7).
pub const Cond = enum(u3) { eq, ne, cs, hi, ge, lt, gt, le };

/// The condition an encoding's three condition bits name.
pub fn condOf(signed: bool, fc0: bool, fc1: bool) Cond {
    const index = @as(u3, @intFromBool(signed)) << 2 | @as(u3, @intFromBool(fc0)) << 1 | @intFromBool(fc1);
    return @fromBackingInt(@intCast(index));
}

/// One element's comparison.
pub fn holds(x: u32, y: u32, size: Size, cond: Cond) bool {
    const ux = int.extend(x, size, true);
    const uy = int.extend(y, size, true);
    const sx = int.extend(x, size, false);
    const sy = int.extend(y, size, false);
    return switch (cond) {
        .eq => ux == uy,
        .ne => ux != uy,
        .cs => ux >= uy,
        .hi => ux > uy,
        .ge => sx >= sy,
        .lt => sx < sy,
        .gt => sx > sy,
        .le => sx <= sy,
    };
}

/// The P0-shaped result of comparing every element of `a` with `b`.
pub fn compare(a: u128, b: u128, size: Size, cond: Cond) u16 {
    const width: u5 = @intCast(qreg.bits(size) / 8);
    const ones: u16 = (@as(u16, 1) << @intCast(width)) - 1;
    var out: u16 = 0;
    for (0..qreg.lanes(size)) |k| {
        const e: u8 = @intCast(k);
        if (holds(qreg.elem(a, size, e), qreg.elem(b, size, e), size, cond)) out |= ones << @intCast(e * width);
    }
    return out;
}
