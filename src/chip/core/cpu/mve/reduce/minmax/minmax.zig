//! MVE VMAXV, VMINV, VMAXAV and VMINAV from the Arm ARM (DDI0553)
//! pseudocode (RA8EMU-25): the max or min of Rda and every active element
//! of Qm. Rda's low esize bits are the starting value, signed for the S
//! forms and unsigned for U and the A forms. Elements are signed except for
//! U, and the A forms take each element's absolute value first. The result
//! is written back extended to 32 bits, matching QEMU's DO_VMAXMINV.
const qreg = @import("../../qreg.zig");
const int = @import("../../int/int.zig");
const predicate = @import("../../predicate.zig");
pub const vectors = @import("vectors.zig");
const Size = qreg.Size;

pub const Kind = enum { max, min };

/// Which of the four instructions, and for VMAXV/VMINV, which signedness.
pub const Form = struct { kind: Kind, unsigned: bool = false, abs: bool = false };

/// The new Rda: `acc` folded with every element of `a` that `mask` keeps.
pub fn maxminv(acc: u32, a: u128, size: Size, mask: u16, form: Form) u32 {
    const w: u6 = @intCast(qreg.bits(size));
    const low: u32 = @truncate(@as(u64, acc) & ((@as(u64, 1) << w) - 1));
    var ra: i64 = int.extend(low, size, form.unsigned or form.abs);
    for (0..qreg.lanes(size)) |k| {
        const e: u8 = @intCast(k);
        if (!predicate.active(mask, size, e)) continue;
        var v = int.extend(qreg.elem(a, size, e), size, form.unsigned);
        if (form.abs and v < 0) v = -v;
        ra = switch (form.kind) {
            .max => @max(ra, v),
            .min => @min(ra, v),
        };
    }
    return @truncate(@as(u64, @bitCast(ra)));
}
