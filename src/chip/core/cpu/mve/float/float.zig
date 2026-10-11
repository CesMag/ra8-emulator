//! MVE floating-point lane arithmetic (RA8EMU-23): VADD, VSUB, VMUL and
//! VABD, the fused VFMA, VFMS and VFMAS, and the sign-bit VABS and VNEG, on
//! F16 and F32 lanes, as pure functions over Q register values.
//!
//! The Arm ARM (DDI0553) runs MVE floating point under StandardFPSCRValue:
//! round to nearest, default NaN and flush-to-zero for single precision,
//! with FPSCR.FZ16 and AHP kept. The cumulative flags still land in FPSCR.
//! As in QEMU's DO_2OP_FP, a lane is computed when any of its bytes is
//! predicated, its flags count only when its first byte is, and the result
//! is merged under the mask, so an unpredicated byte keeps the
//! destination's old value.
const fpu = @import("../../fpu/all.zig");
const Fpscr = fpu.fpscr.Fpscr;
const format = fpu.format;
const qreg = @import("../qreg.zig");
const predicate = @import("../predicate.zig");
pub const abs_vectors = @import("abs_vectors.zig");
pub const cmp = @import("cmp/cmp.zig");
pub const complex = @import("complex/complex.zig");
pub const cvt = @import("cvt/cvt.zig");
pub const fma_vectors = @import("fma_vectors.zig");
pub const int = @import("int/int.zig");
pub const minmax = @import("minmax/minmax.zig");
pub const minmaxv_vectors = @import("minmaxv_vectors.zig");
pub const rint = @import("rint/rint.zig");
pub const scalar = @import("scalar/scalar.zig");
pub const vectors = @import("vectors.zig");

/// The element widths MVE floating point works on.
pub const Size = enum { half, word };

pub const Op = enum { add, sub, mul, abd };

/// StandardFPSCRValue: the controls MVE arithmetic runs under, flags clear.
pub fn standard(fpscr: Fpscr) Fpscr {
    return .{ .rmode = .nearest, .dn = 1, .fz = 1, .fz16 = fpscr.fz16, .ahp = fpscr.ahp };
}

/// Folds the cumulative flags `work` raised into `fpscr`.
pub fn accumulate(fpscr: *Fpscr, work: Fpscr) void {
    const cumulative = fpu.fpscr.mask.cumulative;
    fpscr.* = @bitCast(fpscr.bits() | (work.bits() & cumulative));
}

/// The mask bits of lane `e`'s bytes, shifted down to bit 0: zero means
/// the lane is not computed, bit 0 clear means its flags are dropped.
pub fn laneMask(mask: u16, size: Size, e: u8) u16 {
    const bytes: u8 = if (size == .half) 2 else 4;
    const all: u16 = (@as(u16, 1) << @intCast(bytes)) - 1;
    return mask >> @intCast(bytes * e) & all;
}

pub fn qsize(size: Size) qreg.Size {
    return if (size == .half) .half else .word;
}

/// `op` on every active lane of `a` and `b`, merged into `d` under `mask`.
pub fn binary(d: u128, a: u128, b: u128, size: Size, op: Op, mask: u16, fpscr: *Fpscr) u128 {
    const qs = qsize(size);
    var out = d;
    for (0..qreg.lanes(qs)) |i| {
        const e: u8 = @intCast(i);
        const lane_mask = laneMask(mask, size, e);
        if (lane_mask == 0) continue;
        var work = standard(fpscr.*);
        const x = qreg.elem(a, qs, e);
        const y = qreg.elem(b, qs, e);
        const r = switch (size) {
            .half => @as(u32, lane(format.half, op, @truncate(x), @truncate(y), &work)),
            .word => lane(format.single, op, x, y, &work),
        };
        out = qreg.setElem(out, qs, e, r);
        if (lane_mask & 1 == 1) accumulate(fpscr, work);
    }
    return predicate.merge(d, out, mask);
}

fn lane(comptime fmt: format.Format, op: Op, x: fmt.Bits(), y: fmt.Bits(), work: *Fpscr) fmt.Bits() {
    return switch (op) {
        .add => fpu.add.add(fmt, x, y, work),
        .sub => fpu.add.sub(fmt, x, y, work),
        .mul => fpu.mul.mul(fmt, x, y, work),
        .abd => fpu.add.sub(fmt, x, y, work) & ~signBit(fmt),
    };
}

fn signBit(comptime fmt: format.Format) fmt.Bits() {
    return @as(fmt.Bits(), 1) << @intCast(fmt.width() - 1);
}

/// The one-operand forms. FPAbs and FPNeg only touch the sign bit: no
/// flags, no flushing, and a NaN keeps its payload.
pub const Unary = enum { abs, neg };

/// `op` on every lane of `m`, merged into `d` under `mask`.
pub fn unary(d: u128, m: u128, size: Size, op: Unary, mask: u16) u128 {
    const qs = qsize(size);
    var signs: u128 = 0;
    for (0..qreg.lanes(qs)) |i| {
        const bit: u32 = if (size == .half) signBit(format.half) else signBit(format.single);
        signs = qreg.setElem(signs, qs, @intCast(i), bit);
    }
    const out = switch (op) {
        .abs => m & ~signs,
        .neg => m ^ signs,
    };
    return predicate.merge(d, out, mask);
}

/// The fused forms, each one FPMulAdd(addend, op1, op2) with one rounding:
/// VFMA is d + n*m, VFMS is d + (-n)*m, and VFMAS is m + n*d. A by-scalar
/// form passes the scalar broadcast across `m`.
pub const Fused = enum { fma, fms, fmas };

/// `op` on every active lane of `d`, `n` and `m`, merged into `d` under
/// `mask`.
pub fn fused(d: u128, n: u128, m: u128, size: Size, op: Fused, mask: u16, fpscr: *Fpscr) u128 {
    const qs = qsize(size);
    var out = d;
    for (0..qreg.lanes(qs)) |i| {
        const e: u8 = @intCast(i);
        const lane_mask = laneMask(mask, size, e);
        if (lane_mask == 0) continue;
        var work = standard(fpscr.*);
        const x = qreg.elem(d, qs, e);
        const y = qreg.elem(n, qs, e);
        const z = qreg.elem(m, qs, e);
        const r = switch (size) {
            .half => @as(u32, fusedLane(format.half, op, @truncate(x), @truncate(y), @truncate(z), &work)),
            .word => fusedLane(format.single, op, x, y, z, &work),
        };
        out = qreg.setElem(out, qs, e, r);
        if (lane_mask & 1 == 1) accumulate(fpscr, work);
    }
    return predicate.merge(d, out, mask);
}

fn fusedLane(comptime fmt: format.Format, op: Fused, d: fmt.Bits(), n: fmt.Bits(), m: fmt.Bits(), work: *Fpscr) fmt.Bits() {
    return switch (op) {
        .fma => fpu.fma.vfma(fmt, d, n, m, work),
        .fms => fpu.fma.vfms(fmt, d, n, m, work),
        .fmas => fpu.fma.mulAdd(fmt, m, n, d, work),
    };
}
