//! MVE VCVT between floating point and integer or fixed point (RA8EMU-23):
//! F16 lanes against 16-bit integers and F32 lanes against 32-bit ones, as
//! pure functions over Q register values.
//!
//! Both directions run under StandardFPSCRValue through the scalar
//! FPToFixed and FixedToFP in fpu/. To integer rounds toward zero, or by
//! the rounding a VCVTA/N/P/M encoding names, and a 16-bit result saturates
//! at 16 bits with IOC and no IXC. From integer rounds to nearest. `fbits`
//! is 0 for the integer forms. As in QEMU's DO_VCVT_FIXED and
//! DO_VCVT_RMODE, a lane is computed when any of its bytes is predicated,
//! its flags count only when its first byte is, and the result is merged
//! under the mask.
const fpu = @import("../../../fpu/all.zig");
const Fpscr = fpu.fpscr.Fpscr;
const Rounding = fpu.rounding.Rounding;
const format = fpu.format;
const qreg = @import("../../qreg.zig");
const predicate = @import("../../predicate.zig");
const float = @import("../float.zig");
pub const vectors = @import("vectors.zig");

/// Each float lane of `m` to a signed or `unsigned` integer with `fbits`
/// fraction bits, rounded by `rounding`.
pub fn toInt(d: u128, m: u128, size: float.Size, unsigned: bool, rounding: Rounding, fbits: u6, mask: u16, fpscr: *Fpscr) u128 {
    const qs = float.qsize(size);
    const bytes: u4 = if (size == .half) 2 else 4;
    var out = d;
    for (0..qreg.lanes(qs)) |i| {
        const e: u8 = @intCast(i);
        const lane_mask = laneMask(mask, bytes, e);
        if (lane_mask == 0) continue;
        var work = float.standard(fpscr.*);
        const x = qreg.elem(m, qs, e);
        const r = switch (size) {
            .half => toHalfInt(@truncate(x), unsigned, rounding, fbits, &work),
            .word => fpu.to_int.toFixedBy(format.single, x, fbits, unsigned, rounding, &work),
        };
        out = qreg.setElem(out, qs, e, r);
        if (lane_mask & 1 == 1) float.accumulate(fpscr, work);
    }
    return predicate.merge(d, out, mask);
}

/// Each signed or `unsigned` integer lane of `m`, with `fbits` fraction
/// bits, to a float lane rounded to nearest.
pub fn fromInt(d: u128, m: u128, size: float.Size, unsigned: bool, fbits: u6, mask: u16, fpscr: *Fpscr) u128 {
    const qs = float.qsize(size);
    const bytes: u4 = if (size == .half) 2 else 4;
    var out = d;
    for (0..qreg.lanes(qs)) |i| {
        const e: u8 = @intCast(i);
        const lane_mask = laneMask(mask, bytes, e);
        if (lane_mask == 0) continue;
        var work = float.standard(fpscr.*);
        const x = qreg.elem(m, qs, e);
        const r = switch (size) {
            .half => @as(u32, fpu.fixed.fromFixed(format.half, x, 16, fbits, unsigned, .nearest, &work)),
            .word => fpu.fixed.fromFixed(format.single, x, 32, fbits, unsigned, .nearest, &work),
        };
        out = qreg.setElem(out, qs, e, r);
        if (lane_mask & 1 == 1) float.accumulate(fpscr, work);
    }
    return predicate.merge(d, out, mask);
}

fn laneMask(mask: u16, bytes: u4, e: u8) u16 {
    const all: u16 = (@as(u16, 1) << bytes) - 1;
    return mask >> @intCast(@as(u8, bytes) * e) & all;
}

/// FPToFixed into 16 bits: the 32-bit result saturated to the half range,
/// where saturating raises IOC and drops any IXC, as FPToFixed with N=16.
fn toHalfInt(op: u16, unsigned: bool, rounding: Rounding, fbits: u6, work: *Fpscr) u32 {
    const before = work.*;
    const word = fpu.to_int.toFixedBy(format.half, op, fbits, unsigned, rounding, work);
    const low: u32 = word & 0xFFFF;
    if (unsigned) {
        if (word <= 0xFFFF) return low;
        work.ixc = before.ixc;
        work.ioc = 1;
        return 0xFFFF;
    }
    const value: i32 = @bitCast(word);
    if (value >= -0x8000 and value <= 0x7FFF) return low;
    work.ixc = before.ixc;
    work.ioc = 1;
    return if (value < 0) 0x8000 else 0x7FFF;
}
