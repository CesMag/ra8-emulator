//! MVE floating-point VCMP (RA8EMU-23): the per-byte predicate a compare of
//! F16 or F32 lanes writes into VPR.P0, as a pure function.
//!
//! The Arm ARM (DDI0553) maps each condition onto FPCompareEQ, FPCompareGE
//! or FPCompareGT under StandardFPSCRValue: EQ is FPCompareEQ and NE its
//! negation, GE is FPCompareGE and LT its negation, GT is FPCompareGT and
//! LE its negation. So an unordered lane is true for NE, LT and LE. EQ and
//! NE are quiet (IOC only for a signalling NaN); the ordered conditions
//! signal for any NaN. As QEMU's DO_VCMP_FP does, a lane is compared when
//! any of its bytes is predicated, its flags count only when its first
//! byte is, and the result is masked with the predicate.
const fpu = @import("../../../fpu/all.zig");
const Fpscr = fpu.fpscr.Fpscr;
const format = fpu.format;
const nzcv = fpu.compare.nzcv;
const qreg = @import("../../qreg.zig");
const float = @import("../float.zig");
pub const vectors = @import("vectors.zig");

pub const Cond = enum { eq, ne, ge, lt, gt, le };

/// The predicate bits `n` compared with `m` under `cond` gives, one bit per
/// byte, limited to the active lanes of `mask`. A by-scalar compare passes
/// the scalar broadcast across `m`.
pub fn compare(n: u128, m: u128, size: float.Size, cond: Cond, mask: u16, fpscr: *Fpscr) u16 {
    const qs = float.qsize(size);
    const bytes: u4 = if (size == .half) 2 else 4;
    var out: u16 = 0;
    for (0..qreg.lanes(qs)) |i| {
        const e: u8 = @intCast(i);
        const lane_mask = float.laneMask(mask, size, e);
        if (lane_mask == 0) continue;
        var work = float.standard(fpscr.*);
        const x = qreg.elem(n, qs, e);
        const y = qreg.elem(m, qs, e);
        const flags = switch (size) {
            .half => fpu.compare.compare(format.half, @truncate(x), @truncate(y), signals(cond), &work),
            .word => fpu.compare.compare(format.single, x, y, signals(cond), &work),
        };
        if (holds(cond, flags)) {
            const lane_bits: u16 = (@as(u16, 1) << bytes) - 1;
            out |= lane_bits << @intCast(@as(u8, bytes) * e);
        }
        if (lane_mask & 1 == 1) float.accumulate(fpscr, work);
    }
    return out & mask;
}

fn signals(cond: Cond) bool {
    return switch (cond) {
        .eq, .ne => false,
        .ge, .lt, .gt, .le => true,
    };
}

fn holds(cond: Cond, flags: u4) bool {
    const eq = flags == nzcv.equal;
    const gt = flags == nzcv.greater;
    return switch (cond) {
        .eq => eq,
        .ne => !eq,
        .ge => eq or gt,
        .lt => !(eq or gt),
        .gt => gt,
        .le => !gt,
    };
}
