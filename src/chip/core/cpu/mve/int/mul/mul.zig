//! MVE high-half and doubling multiplies, and the scalar multiply-adds,
//! from the Arm ARM (DDI0553) pseudocode (RA8EMU-25). VMULH keeps the top
//! half of each double-width lane product and VRMULH rounds it first.
//! VQDMULH doubles the product before taking the top half, and VQRDMULH
//! also rounds; both saturate, which happens only for the most negative
//! value times itself, and report it for FPSCR.QC. VMLA adds the lane times
//! a scalar to Qda; VMLAS multiplies Qda by the lane and adds the scalar.
//! VQDMLAH doubles the lane times the scalar and adds Qda shifted up by the
//! lane width; VQDMLASH doubles the lane times Qda and adds the shifted
//! scalar. The R forms round, and all four keep the saturated top half.
const qreg = @import("../../qreg.zig");
const int = @import("../int.zig");
pub const vectors = @import("vectors.zig");
const Size = qreg.Size;

/// Which high-half multiply: signedness, rounding and doubling.
pub const High = struct { unsigned: bool = false, round: bool = false, double: bool = false };

/// VMULH, VRMULH, VQDMULH or VQRDMULH (vector).
pub fn multiplyHigh(a: u128, b: u128, size: Size, h: High) int.Sat {
    const w: u7 = @intCast(qreg.bits(size));
    const lim = int.bounds(size, false);
    var out: u128 = 0;
    var saturated = false;
    for (0..qreg.lanes(size)) |k| {
        const e: u8 = @intCast(k);
        const x: i128 = int.extend(qreg.elem(a, size, e), size, h.unsigned);
        const y: i128 = int.extend(qreg.elem(b, size, e), size, h.unsigned);
        var p = x * y;
        if (h.double) p *= 2;
        if (h.round) p += @as(i128, 1) << (w - 1);
        var r = p >> w;
        if (h.double) {
            const c = @min(@max(r, lim[0]), lim[1]);
            saturated = saturated or c != r;
            r = c;
        }
        out = qreg.setElem(out, size, e, @truncate(@as(u128, @bitCast(r))));
    }
    return .{ .value = out, .saturated = saturated };
}

/// Whether the scalar multiplies the lane (VMLA) or is added (VMLAS).
pub const ScalarForm = enum { vmla, vmlas };

/// VMLA or VMLAS (vector by scalar), modulo the lane width. The scalar is
/// the bottom lane-width bits of the general-purpose register.
pub fn multiplyAddScalar(da: u128, n: u128, scalar: u32, size: Size, form: ScalarForm) u128 {
    var out: u128 = 0;
    for (0..qreg.lanes(size)) |k| {
        const e: u8 = @intCast(k);
        const d = qreg.elem(da, size, e);
        const x = qreg.elem(n, size, e);
        const r = switch (form) {
            .vmla => d +% x *% scalar,
            .vmlas => d *% x +% scalar,
        };
        out = qreg.setElem(out, size, e, r);
    }
    return out;
}

/// VQ{R}DMLAH multiplies by the scalar and adds Qda; VQ{R}DMLASH multiplies
/// by Qda and adds the scalar. `round` selects the R forms.
pub const DoublingForm = struct { scalar_addend: bool = false, round: bool = false };

/// VQDMLAH, VQRDMLAH, VQDMLASH or VQRDMLASH (vector by scalar): per lane,
/// SignedSatQ((2*n*m + (c << esize) + round) >> esize, esize).
pub fn doublingMultiplyAccumulateHigh(da: u128, n: u128, scalar: u32, size: Size, form: DoublingForm) int.Sat {
    const w: u7 = @intCast(qreg.bits(size));
    const lim = int.bounds(size, false);
    const s: i128 = int.extend(qreg.elem(scalar, size, 0), size, false);
    var out: u128 = 0;
    var saturated = false;
    for (0..qreg.lanes(size)) |k| {
        const e: u8 = @intCast(k);
        const x: i128 = int.extend(qreg.elem(n, size, e), size, false);
        const d: i128 = int.extend(qreg.elem(da, size, e), size, false);
        var v = if (form.scalar_addend) 2 * x * d + (s << w) else 2 * x * s + (d << w);
        if (form.round) v += @as(i128, 1) << (w - 1);
        const r = v >> w;
        const c = @min(@max(r, lim[0]), lim[1]);
        saturated = saturated or c != r;
        out = qreg.setElem(out, size, e, @truncate(@as(u128, @bitCast(c))));
    }
    return .{ .value = out, .saturated = saturated };
}
