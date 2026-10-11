//! MVE narrowing and widening moves and shifts from the Arm ARM (DDI0553)
//! pseudocode (RA8EMU-25). A narrowing op (VMOVN, VQMOVN, VQMOVUN, VSHRN,
//! VRSHRN, VQSHRN, VQRSHRN, VQSHRUN) reads each double-width lane of Qm,
//! shifts it right, optionally rounds and saturates, and writes it into the
//! bottom or top half of that lane in Qd, keeping the other half of Qd. A
//! widening op (VMOVL, VSHLL) reads the bottom or top half-lanes of Qm,
//! extends them, and shifts them left.
const qreg = @import("../../qreg.zig");
const int = @import("../int.zig");
const shift = @import("../shift/shift.zig");
pub const vectors = @import("vectors.zig");
const Size = qreg.Size;

/// Which half of each double-width lane an op reads or writes (the B/T
/// suffix of the mnemonic).
pub const Half = enum(u1) { bottom = 0, top = 1 };

/// How a narrowing op treats its lanes: the right shift, rounding,
/// saturation, and the signedness of the source and of the saturated
/// result (VQMOVUN and VQSHRUN read signed and saturate unsigned).
pub const Narrow = struct {
    shift: u5 = 0,
    round: bool = false,
    saturate: bool = false,
    in_unsigned: bool = false,
    out_unsigned: bool = false,
};

/// The lane size twice as wide as `size`.
pub fn wider(size: Size) Size {
    return switch (size) {
        .byte => .half,
        .half => .word,
        .word => unreachable,
    };
}

/// A narrowing op into lanes of `size`, writing `half` of each pair in `d`.
pub fn narrow(d: u128, m: u128, size: Size, half: Half, spec: Narrow) int.Sat {
    const wide = wider(size);
    const lim = int.bounds(size, spec.out_unsigned);
    var out = d;
    var saturated = false;
    for (0..qreg.lanes(wide)) |k| {
        const e: u8 = @intCast(k);
        const x = int.extend(qreg.elem(m, wide, e), wide, spec.in_unsigned);
        var r = shift.shiftLane(x, -@as(i8, spec.shift), spec.round);
        if (spec.saturate) {
            const c = @min(@max(r, lim[0]), lim[1]);
            saturated = saturated or c != r;
            r = c;
        }
        out = qreg.setElem(out, size, 2 * e + @backingInt(half), @truncate(@as(u128, @bitCast(r))));
    }
    return .{ .value = out, .saturated = saturated };
}

/// VMOVL (shift 0) or VSHLL: `half` of each lane pair of `m`, read as
/// lanes of `size`, extended to twice the width and shifted left.
pub fn widen(m: u128, size: Size, half: Half, unsigned: bool, left: u6) u128 {
    const wide = wider(size);
    var out: u128 = 0;
    for (0..qreg.lanes(wide)) |k| {
        const e: u8 = @intCast(k);
        const x = int.extend(qreg.elem(m, size, 2 * e + @backingInt(half)), size, unsigned);
        const r = x << left;
        out = qreg.setElem(out, wide, e, @truncate(@as(u64, @bitCast(r))));
    }
    return out;
}
