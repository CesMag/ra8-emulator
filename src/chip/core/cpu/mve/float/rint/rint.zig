//! MVE VRINTA/N/P/M/Z/X (RA8EMU-23): each F16 or F32 lane rounded to an
//! integral float value, as a pure function over Q register values.
//!
//! Every form runs FPRoundInt under StandardFPSCRValue (DN and FZ set).
//! A/N/P/M/Z name their rounding and never raise IXC; X rounds to nearest
//! and raises IXC when the value changed. As in QEMU's DO_VCVT_RMODE and
//! DO_1OP_FP, a lane is computed when any of its bytes is predicated, its
//! flags count only when its first byte is, and the result is merged under
//! the mask.
const fpu = @import("../../../fpu/all.zig");
const Fpscr = fpu.fpscr.Fpscr;
const Rounding = fpu.rounding.Rounding;
const format = fpu.format;
const qreg = @import("../../qreg.zig");
const predicate = @import("../../predicate.zig");
const float = @import("../float.zig");
pub const vectors = @import("vectors.zig");

pub const Kind = enum {
    a,
    n,
    p,
    m,
    z,
    x,

    /// The rounding the encoding names; X takes the standard nearest.
    pub fn rounding(kind: Kind) Rounding {
        return switch (kind) {
            .a => .ties_away,
            .n, .x => .nearest,
            .p => .plus_inf,
            .m => .minus_inf,
            .z => .zero,
        };
    }
};

/// Each lane of `m` rounded to an integral value by `kind`.
pub fn rint(d: u128, m: u128, size: float.Size, kind: Kind, mask: u16, fpscr: *Fpscr) u128 {
    const qs = float.qsize(size);
    const bytes: u8 = if (size == .half) 2 else 4;
    const all: u16 = (@as(u16, 1) << @intCast(bytes)) - 1;
    const exact = kind == .x;
    var out = d;
    for (0..qreg.lanes(qs)) |i| {
        const e: u8 = @intCast(i);
        const lane_mask = mask >> @intCast(bytes * e) & all;
        if (lane_mask == 0) continue;
        var work = float.standard(fpscr.*);
        const x = qreg.elem(m, qs, e);
        const r: u32 = switch (size) {
            .half => fpu.rint.rint(format.half, @truncate(x), kind.rounding(), exact, &work),
            .word => fpu.rint.rint(format.single, @truncate(x), kind.rounding(), exact, &work),
        };
        out = qreg.setElem(out, qs, e, r);
        if (lane_mask & 1 == 1) float.accumulate(fpscr, work);
    }
    return predicate.merge(d, out, mask);
}
