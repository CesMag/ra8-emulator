//! MVE integer shifts from the Arm ARM (DDI0553) pseudocode (RA8EMU-25).
//! The register forms (VSHL, VRSHL, VQSHL, VQRSHL) take each lane's shift
//! from the signed bottom byte of the matching lane of the second operand:
//! positive shifts left, negative shifts right (arithmetic when the lane is
//! signed). The immediate forms (VSHL, VSHR, VRSHR, VQSHL) are the same
//! operation with one shift for every lane. Rounding adds half the weight of
//! the lowest bit kept; saturating forms clamp to the lane range and report
//! it for FPSCR.QC. VQSHLU reads signed lanes and saturates them unsigned.
const std = @import("std");
const qreg = @import("../../qreg.zig");
const int = @import("../int.zig");
pub const vectors = @import("vectors.zig");
const Size = qreg.Size;

/// How the shifted lane is finished. `saturate_unsigned` clamps to the
/// unsigned range even when the lane is read signed (VQSHLU).
pub const Mode = struct {
    unsigned: bool = false,
    round: bool = false,
    saturate: bool = false,
    saturate_unsigned: bool = false,
};

/// One lane shifted at full precision. Shifts past 33 left or 64 right give
/// the same lane result and saturation as any larger amount, so they are
/// clamped there to keep the arithmetic inside i128.
pub fn shiftLane(x: i64, shift: i8, round: bool) i128 {
    const s = std.math.clamp(@as(i32, shift), -64, 33);
    const v: i128 = x;
    if (s >= 0) return v << @intCast(s);
    const n: u7 = @intCast(-s);
    const half: i128 = if (round) @as(i128, 1) << (n - 1) else 0;
    return (v + half) >> n;
}

/// The register forms: each lane of `a` shifted by the bottom byte of the
/// matching lane of `b`.
pub fn byRegister(a: u128, b: u128, size: Size, mode: Mode) int.Sat {
    const lim = int.bounds(size, mode.unsigned or mode.saturate_unsigned);
    var out: u128 = 0;
    var saturated = false;
    for (0..qreg.lanes(size)) |k| {
        const e: u8 = @intCast(k);
        const x = int.extend(qreg.elem(a, size, e), size, mode.unsigned);
        const shift: i8 = @bitCast(@as(u8, @truncate(qreg.elem(b, size, e))));
        var r = shiftLane(x, shift, mode.round);
        if (mode.saturate) {
            const c = std.math.clamp(r, lim[0], lim[1]);
            saturated = saturated or c != r;
            r = c;
        }
        out = qreg.setElem(out, size, e, @truncate(@as(u128, @bitCast(r))));
    }
    return .{ .value = out, .saturated = saturated };
}

/// The immediate forms: every lane of `a` shifted by `shift` (negative for
/// VSHR and VRSHR).
pub fn byImmediate(a: u128, shift: i8, size: Size, mode: Mode) int.Sat {
    return byRegister(a, splat(shift, size), size, mode);
}

/// `shift` in the bottom byte of every lane.
pub fn splat(shift: i8, size: Size) u128 {
    var out: u128 = 0;
    for (0..qreg.lanes(size)) |k| {
        out = qreg.setElem(out, size, @intCast(k), @as(u8, @bitCast(shift)));
    }
    return out;
}
