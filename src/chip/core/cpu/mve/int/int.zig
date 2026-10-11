//! MVE integer lane arithmetic from the Arm ARM (DDI0553) pseudocode
//! (RA8EMU-25): VADD, VSUB and VMUL keep the low bits of each lane, and
//! VQADD and VQSUB clamp each lane to its signed or unsigned range and
//! report whether any lane clamped, which the caller turns into FPSCR.QC.
//! VABD, VMAX, VMIN and the halving adds and subtract read each lane signed
//! or unsigned and work at full precision before the result is narrowed.
//! Every function works on the whole 128-bit vector; predication and
//! beats are applied by whoever writes the result back.
const qreg = @import("../qreg.zig");
pub const insert = @import("insert/insert.zig");
pub const mul = @import("mul/mul.zig");
pub const shift = @import("shift/shift.zig");
pub const vectors = @import("vectors.zig");
pub const width = @import("width/width.zig");
const Size = qreg.Size;

pub const Op = enum { add, sub, mul };

/// A saturating result: the clamped vector and whether any lane clamped.
pub const Sat = struct { value: u128, saturated: bool };

/// VADD, VSUB or VMUL (vector) on every lane, modulo the lane width.
pub fn lanewise(a: u128, b: u128, size: Size, op: Op) u128 {
    var out: u128 = 0;
    for (0..qreg.lanes(size)) |k| {
        const e: u8 = @intCast(k);
        const x = qreg.elem(a, size, e);
        const y = qreg.elem(b, size, e);
        const r = switch (op) {
            .add => x +% y,
            .sub => x -% y,
            .mul => x *% y,
        };
        out = qreg.setElem(out, size, e, r);
    }
    return out;
}

/// The lane `x` read as signed or unsigned.
pub fn extend(x: u32, size: Size, unsigned: bool) i64 {
    if (unsigned) return x;
    const w: u6 = @intCast(qreg.bits(size));
    const wide: i64 = x;
    return if (x >> @intCast(w - 1) & 1 == 1) wide - (@as(i64, 1) << w) else wide;
}

/// The bounds SatQ or UnsignedSatQ clamps a lane to.
pub fn bounds(size: Size, unsigned: bool) [2]i64 {
    const w: u6 = @intCast(qreg.bits(size));
    if (unsigned) return .{ 0, (@as(i64, 1) << w) - 1 };
    return .{ -(@as(i64, 1) << (w - 1)), (@as(i64, 1) << (w - 1)) - 1 };
}

/// VQADD or VQSUB (vector).
pub fn saturating(a: u128, b: u128, size: Size, unsigned: bool, sub: bool) Sat {
    const lim = bounds(size, unsigned);
    var out: u128 = 0;
    var saturated = false;
    for (0..qreg.lanes(size)) |k| {
        const e: u8 = @intCast(k);
        const x = extend(qreg.elem(a, size, e), size, unsigned);
        const y = extend(qreg.elem(b, size, e), size, unsigned);
        const r = if (sub) x - y else x + y;
        const c = @min(@max(r, lim[0]), lim[1]);
        saturated = saturated or c != r;
        out = qreg.setElem(out, size, e, @truncate(@as(u64, @bitCast(c))));
    }
    return .{ .value = out, .saturated = saturated };
}

pub const Pairwise = enum { abd, max, min, hadd, rhadd, hsub };

/// One lane of VABD, VMAX, VMIN, VHADD, VRHADD or VHSUB at full precision.
pub fn pairLane(x: i64, y: i64, op: Pairwise) i64 {
    return switch (op) {
        .abd => @intCast(@abs(x - y)),
        .max => @max(x, y),
        .min => @min(x, y),
        .hadd => (x + y) >> 1,
        .rhadd => (x + y + 1) >> 1,
        .hsub => (x - y) >> 1,
    };
}

/// VABD, VMAX, VMIN, VHADD, VRHADD or VHSUB (vector) on every lane.
pub fn pairwise(a: u128, b: u128, size: Size, unsigned: bool, op: Pairwise) u128 {
    var out: u128 = 0;
    for (0..qreg.lanes(size)) |k| {
        const e: u8 = @intCast(k);
        const x = extend(qreg.elem(a, size, e), size, unsigned);
        const y = extend(qreg.elem(b, size, e), size, unsigned);
        const r = pairLane(x, y, op);
        out = qreg.setElem(out, size, e, @truncate(@as(u64, @bitCast(r))));
    }
    return out;
}
