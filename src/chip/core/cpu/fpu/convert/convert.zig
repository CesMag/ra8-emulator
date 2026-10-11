//! FPConvert from the Arm ARM (DDI0553) between single and double
//! precision, the arithmetic behind VCVT.F64.F32 and VCVT.F32.F64.
//!
//! The operand is unpacked in its own format (FZ flushes a denormal and
//! sets IDC). A NaN raises IOC when signalling, gives the default NaN under
//! DN, and otherwise keeps its sign and the top of its payload with the
//! quiet bit set (FPConvertNaN). Zeros and infinities keep their sign.
//! Every other value goes through FPRound in the target format under the
//! FPSCR rounding mode, so widening is exact and narrowing can raise OFC,
//! UFC and IXC.
const format = @import("../format.zig");
const Format = format.Format;
const unpack_mod = @import("../unpack.zig");
const nan = @import("../nan.zig");
const round = @import("../round.zig");
const Fpscr = @import("../fpscr.zig").Fpscr;
pub const vectors = @import("vectors.zig");

pub fn convert(comptime from: Format, comptime to: Format, op: from.Bits(), fpscr: *Fpscr) to.Bits() {
    const u = unpack_mod.unpack(from, op, fpscr);
    switch (u.kind) {
        .snan, .qnan => {
            if (u.kind == .snan) fpscr.ioc = 1;
            if (fpscr.dn == 1) return nan.defaultNaN(to);
            return convertNaN(from, to, op);
        },
        .zero => return to.zero(u.sign),
        .infinity => return to.infinity(u.sign),
        .nonzero => return round.round(to, u.real, fpscr, fpscr.rmode),
    }
}

/// FPConvertNaN: the sign, then the payload aligned at the top of the
/// target fraction (truncated or zero-filled), with the quiet bit set.
pub fn convertNaN(comptime from: Format, comptime to: Format, op: from.Bits()) to.Bits() {
    const sign: u1 = @intCast(op >> @intCast(from.width() - 1));
    const frac: u128 = op & from.fracMask();
    const moved: u128 = if (to.frac_bits >= from.frac_bits)
        frac << (to.frac_bits - from.frac_bits)
    else
        frac >> (from.frac_bits - to.frac_bits);
    const payload: to.Bits() = @truncate(moved);
    return to.pack(sign, to.expMask(), payload | nan.quietBit(to));
}
