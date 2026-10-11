//! MVE complex arithmetic on F16 and F32 lane pairs (RA8EMU-23): VCADD
//! (rotation 90 or 270), VCMLA (fused, rotation 0/90/180/270) and VCMUL,
//! as pure functions over Q register values. An even lane holds the real
//! part and the odd lane above it the imaginary part.
//!
//! All run under StandardFPSCRValue. VCADD follows QEMU's DO_VCADD_FP: each
//! lane is computed when any of its bytes is predicated and its flags count
//! only when its first byte is. VCMLA and VCMUL follow DO_VCMLA: a pair is
//! computed when any of its bytes is predicated, and each half's flags
//! count only when that half's first byte is. Every result is merged under
//! the mask. A rotation negates its operand by flipping the sign bit, which
//! is exact, so VCMLA stays one FPMulAdd per lane.
const fpu = @import("../../../fpu/all.zig");
const Fpscr = fpu.fpscr.Fpscr;
const format = fpu.format;
const Format = format.Format;
const qreg = @import("../../qreg.zig");
const predicate = @import("../../predicate.zig");
const float = @import("../float.zig");
pub const vectors = @import("vectors.zig");

/// VCADD: rotation 90 gives (n.re - m.im, n.im + m.re), 270 the other way.
pub fn cadd(d: u128, n: u128, m: u128, size: float.Size, rot270: bool, mask: u16, fpscr: *Fpscr) u128 {
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
        const y = qreg.elem(m, qs, e ^ 1);
        const subtract = (e & 1 == 0) != rot270;
        const r: u32 = switch (size) {
            .half => addSub(format.half, @truncate(x), @truncate(y), subtract, &work),
            .word => addSub(format.single, @truncate(x), @truncate(y), subtract, &work),
        };
        out = qreg.setElem(out, qs, e, r);
        if (lane_mask & 1 == 1) float.accumulate(fpscr, work);
    }
    return predicate.merge(d, out, mask);
}

/// VCMLA (`accumulate`) or VCMUL with rotation `rot` times 90 degrees.
pub fn cmla(d: u128, n: u128, m: u128, size: float.Size, rot: u2, accumulate: bool, mask: u16, fpscr: *Fpscr) u128 {
    const qs = float.qsize(size);
    const bytes: u8 = if (size == .half) 2 else 4;
    const pair_bits: u16 = (@as(u16, 1) << @intCast(bytes * 2)) - 1;
    var out = d;
    var e: u8 = 0;
    while (e < qreg.lanes(qs)) : (e += 2) {
        const pair_mask = mask >> @intCast(bytes * e) & pair_bits;
        if (pair_mask == 0) continue;
        for ([_]u8{ e, e + 1 }) |lane_index| {
            var work = float.standard(fpscr.*);
            const r = halfOf(d, n, m, size, rot, accumulate, e, lane_index, &work);
            out = qreg.setElem(out, qs, lane_index, r);
            const first_bit = @as(u16, bytes) * (lane_index - e);
            if (pair_mask >> @intCast(first_bit) & 1 == 1) float.accumulate(fpscr, work);
        }
    }
    return predicate.merge(d, out, mask);
}

/// One lane of a VCMLA/VCMUL pair starting at `e`: the operand pair the
/// rotation picks, then d + n * m (fused) or n * m.
fn halfOf(d: u128, n: u128, m: u128, size: float.Size, rot: u2, accumulate: bool, e: u8, lane_index: u8, work: *Fpscr) u32 {
    const qs = float.qsize(size);
    const odd = lane_index != e;
    // rot 0: n.re*m.re, n.re*m.im; 90: n.im*-m.im, n.im*m.re;
    // 180: n.re*-m.re, n.re*-m.im; 270: n.im*m.im, n.im*-m.re.
    const n_index = if (rot & 1 == 1) e + 1 else e;
    const m_index = if (rot & 1 == 1) (if (odd) e else e + 1) else lane_index;
    const negate = switch (rot) {
        0 => false,
        1 => !odd,
        2 => true,
        3 => odd,
    };
    const x = qreg.elem(n, qs, n_index);
    const y = qreg.elem(m, qs, m_index);
    const acc = qreg.elem(d, qs, lane_index);
    return switch (size) {
        .half => product(format.half, @truncate(acc), @truncate(x), @truncate(y), negate, accumulate, work),
        .word => product(format.single, @truncate(acc), @truncate(x), @truncate(y), negate, accumulate, work),
    };
}

fn product(comptime fmt: Format, acc: fmt.Bits(), x: fmt.Bits(), y: fmt.Bits(), negate: bool, accumulate: bool, work: *Fpscr) fmt.Bits() {
    const y2 = if (negate) y ^ signBit(fmt) else y;
    if (accumulate) return fpu.fma.mulAdd(fmt, acc, x, y2, work);
    return fpu.mul.mul(fmt, x, y2, work);
}

fn addSub(comptime fmt: Format, x: fmt.Bits(), y: fmt.Bits(), subtract: bool, work: *Fpscr) fmt.Bits() {
    if (subtract) return fpu.add.sub(fmt, x, y, work);
    return fpu.add.add(fmt, x, y, work);
}

fn signBit(comptime fmt: Format) fmt.Bits() {
    return @as(fmt.Bits(), 1) << @intCast(fmt.width() - 1);
}
