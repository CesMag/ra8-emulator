//! The MVE floating-point forms that take a general-purpose register as
//! their second operand (RA8EMU-23): VADD, VSUB, VMUL, VFMA and VFMAS
//! (Qd, Qn, Rm), and VCMP (Qn, Rm), on F16 and F32 lanes.
//!
//! Each broadcasts the scalar into every lane and runs the vector form, so
//! the arithmetic, flags and predication match those exactly, as in QEMU's
//! DO_2OP_FP_SCALAR, DO_2OP_FP_ACC_SCALAR and DO_VCMP_FP_SCALAR. An F16
//! form reads only the low 16 bits of Rm. VFMA is d + n*Rm and VFMAS is
//! d*n + Rm.
const Fpscr = @import("../../../fpu/fpscr.zig").Fpscr;
const qreg = @import("../../qreg.zig");
const float = @import("../float.zig");
const float_cmp = @import("../cmp/cmp.zig");
pub const vectors = @import("vectors.zig");

/// `rm` (its low 16 bits for F16) copied into every lane.
pub fn broadcast(rm: u32, size: float.Size) u128 {
    const qs = float.qsize(size);
    const value: u32 = if (size == .half) rm & 0xFFFF else rm;
    var out: u128 = 0;
    for (0..qreg.lanes(qs)) |i| out = qreg.setElem(out, qs, @intCast(i), value);
    return out;
}

/// VADD, VSUB or VMUL of each lane of `n` with the scalar `rm`.
pub fn binary(d: u128, n: u128, rm: u32, size: float.Size, op: float.Op, mask: u16, fpscr: *Fpscr) u128 {
    return float.binary(d, n, broadcast(rm, size), size, op, mask, fpscr);
}

/// VFMA (`.fma`) or VFMAS (`.fmas`) with the scalar `rm`.
pub fn fused(d: u128, n: u128, rm: u32, size: float.Size, op: float.Fused, mask: u16, fpscr: *Fpscr) u128 {
    return float.fused(d, n, broadcast(rm, size), size, op, mask, fpscr);
}

/// VCMP of each lane of `n` against the scalar `rm`: the new VPR.P0.
pub fn compare(n: u128, rm: u32, size: float.Size, cond: float_cmp.Cond, mask: u16, fpscr: *Fpscr) u16 {
    return float_cmp.compare(n, broadcast(rm, size), size, cond, mask, fpscr);
}
