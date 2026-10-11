//! MVE VMAXNM/VMINNM, VMAXNMA/VMINNMA and the VMAXNMV/VMINNMV/VMAXNMAV/
//! VMINNMAV reductions (RA8EMU-23) on F16 and F32 lanes, as pure functions
//! over Q register values.
//!
//! All run FPMaxNum/FPMinNum under StandardFPSCRValue (DN and FZ set). The
//! A forms clear the sign of both lane operands first. The lane ops follow
//! QEMU's DO_2OP_FP_ALL: a lane is computed when any of its bytes is
//! predicated, its flags count only when its first byte is, and the result
//! is merged under the mask. The reductions follow DO_FP_VMAXMINV: only
//! lanes whose first byte is predicated fold into the scalar, a signalling
//! NaN in the scalar or the lane is quietened with IOC before the fold (so
//! it then loses to a number), the A forms take the lane's absolute value
//! but not the scalar's, and an F16 result is zero-extended into Rda.
const fpu = @import("../../../fpu/all.zig");
const Fpscr = fpu.fpscr.Fpscr;
const Which = fpu.minmax.Which;
const format = fpu.format;
const Format = format.Format;
const qreg = @import("../../qreg.zig");
const predicate = @import("../../predicate.zig");
const float = @import("../float.zig");
pub const vectors = @import("vectors.zig");

/// FPMaxNum or FPMinNum lane by lane; `abs` gives the A forms.
pub fn lanes(d: u128, n: u128, m: u128, size: float.Size, which: Which, abs: bool, mask: u16, fpscr: *Fpscr) u128 {
    const qs = float.qsize(size);
    const bytes: u8 = if (size == .half) 2 else 4;
    const all: u16 = (@as(u16, 1) << @intCast(bytes)) - 1;
    var out = d;
    for (0..qreg.lanes(qs)) |i| {
        const e: u8 = @intCast(i);
        const lane_mask = mask >> @intCast(bytes * e) & all;
        if (lane_mask == 0) continue;
        var work = float.standard(fpscr.*);
        const x = qreg.elem(n, qs, e);
        const y = qreg.elem(m, qs, e);
        const r: u32 = switch (size) {
            .half => lane(format.half, @truncate(x), @truncate(y), which, abs, &work),
            .word => lane(format.single, @truncate(x), @truncate(y), which, abs, &work),
        };
        out = qreg.setElem(out, qs, e, r);
        if (lane_mask & 1 == 1) float.accumulate(fpscr, work);
    }
    return predicate.merge(d, out, mask);
}

/// Folds the predicated lanes of `m` into the scalar `ra` (its low 16 bits
/// for F16); `abs` gives the AV forms.
pub fn reduce(ra: u32, m: u128, size: float.Size, which: Which, abs: bool, mask: u16, fpscr: *Fpscr) u32 {
    var work = float.standard(fpscr.*);
    const r: u32 = switch (size) {
        .half => fold(format.half, @truncate(ra), m, which, abs, mask, &work),
        .word => fold(format.single, ra, m, which, abs, mask, &work),
    };
    float.accumulate(fpscr, work);
    return r;
}

fn lane(comptime fmt: Format, x: fmt.Bits(), y: fmt.Bits(), which: Which, abs: bool, work: *Fpscr) fmt.Bits() {
    if (!abs) return fpu.minmax.num(fmt, x, y, which, work);
    return fpu.minmax.num(fmt, x & ~signBit(fmt), y & ~signBit(fmt), which, work);
}

fn fold(comptime fmt: Format, ra: fmt.Bits(), m: u128, which: Which, abs: bool, mask: u16, work: *Fpscr) fmt.Bits() {
    const qs = float.qsize(if (fmt.width() == 16) .half else .word);
    const bytes: u8 = @intCast(fmt.width() / 8);
    var acc = ra;
    for (0..qreg.lanes(qs)) |i| {
        const e: u8 = @intCast(i);
        if (mask >> @intCast(bytes * e) & 1 == 0) continue;
        var v: fmt.Bits() = @truncate(qreg.elem(m, qs, e));
        acc = quieten(fmt, acc, work);
        v = quieten(fmt, v, work);
        if (abs) v &= ~signBit(fmt);
        acc = fpu.minmax.num(fmt, acc, v, which, work);
    }
    return acc;
}

/// A signalling NaN made quiet, raising IOC; anything else unchanged.
fn quieten(comptime fmt: Format, x: fmt.Bits(), work: *Fpscr) fmt.Bits() {
    const q = fpu.nan.quietBit(fmt);
    const exp_field = x >> fmt.frac_bits & fmt.expMask();
    const is_nan = exp_field == fmt.expMask() and x & fmt.fracMask() != 0;
    if (!is_nan or x & q != 0) return x;
    work.ioc = 1;
    return x | q;
}

fn signBit(comptime fmt: Format) fmt.Bits() {
    return @as(fmt.Bits(), 1) << @intCast(fmt.width() - 1);
}
