//! MVE VCVTB and VCVTT between half and single precision (RA8EMU-23), as
//! pure functions over Q register values.
//!
//! Each word lane converts on its own under StandardFPSCRValue, through the
//! scalar FPConvert in src/chip/core/cpu/fpu/half/half.zig: a single operand is flushed by FZ, a
//! half operand or result never is, and AHP is kept. F32 to F16 writes the
//! bottom (VCVTB) or top (VCVTT) half of each destination word and keeps the
//! other half; F16 to F32 reads that half of each source word. Following
//! QEMU's do_vcvt_sh and do_vcvt_hs, a lane is computed when any of its
//! bytes is predicated, its flags count only when the byte it reads (F16 to
//! F32) or the lane's first byte (F32 to F16) is, and the bytes written are
//! merged under the mask.
const fpu = @import("../../../fpu/all.zig");
const Fpscr = fpu.fpscr.Fpscr;
const format = fpu.format;
const qreg = @import("../../qreg.zig");
const predicate = @import("../../predicate.zig");
const float = @import("../float.zig");
pub const vectors = @import("vectors.zig");

/// F32 lanes of `m` rounded to F16 in the bottom or `top` half of each word
/// of `d`.
pub fn toHalf(d: u128, m: u128, top: bool, mask: u16, fpscr: *Fpscr) u128 {
    var out = d;
    for (0..4) |i| {
        const e: u8 = @intCast(i);
        const lane_mask = mask >> @intCast(4 * e) & 0xF;
        if (lane_mask == 0) continue;
        var work = float.standard(fpscr.*);
        const h = fpu.half.toHalf(format.single, qreg.elem(m, .word, e), &work);
        out = qreg.setElem(out, .word, e, fpu.half.place(qreg.elem(d, .word, e), h, top));
        if (lane_mask & 1 == 1) float.accumulate(fpscr, work);
    }
    return predicate.merge(d, out, mask);
}

/// The bottom or `top` F16 half of each word of `m` widened to an F32 lane
/// of `d`.
pub fn fromHalf(d: u128, m: u128, top: bool, mask: u16, fpscr: *Fpscr) u128 {
    const read_bit: u4 = if (top) 2 else 0;
    var out = d;
    for (0..4) |i| {
        const e: u8 = @intCast(i);
        const lane_mask = mask >> @intCast(4 * e) & 0xF;
        if (lane_mask == 0) continue;
        var work = float.standard(fpscr.*);
        const h = fpu.half.lane(qreg.elem(m, .word, e), top);
        out = qreg.setElem(out, .word, e, fpu.half.fromHalf(format.single, h, &work));
        if (lane_mask >> read_bit & 1 == 1) float.accumulate(fpscr, work);
    }
    return predicate.merge(d, out, mask);
}
