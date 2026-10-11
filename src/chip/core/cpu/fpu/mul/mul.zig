//! FPMul from the Arm ARM (DDI0553), the arithmetic behind VMUL, and the
//! VNMUL form, which negates the rounded product with FPNeg (so a NaN result
//! has its sign flipped too).
//!
//! NaN operands are handled first. Then infinity times zero is invalid
//! (default NaN, IOC); otherwise an infinity or a zero operand gives an
//! infinity or zero whose sign is the XOR of the operand signs. Everything
//! else is the exact product, rounded once by FPRound.
const format = @import("../format.zig");
const Format = format.Format;
const unpack_mod = @import("../unpack.zig");
const nan = @import("../nan.zig");
const round = @import("../round.zig");
const Fpscr = @import("../fpscr.zig").Fpscr;
pub const vectors = @import("vectors.zig");

pub fn mul(comptime fmt: Format, op1: fmt.Bits(), op2: fmt.Bits(), fpscr: *Fpscr) fmt.Bits() {
    const a = unpack_mod.unpack(fmt, op1, fpscr);
    const b = unpack_mod.unpack(fmt, op2, fpscr);
    if (nan.processNaNs(fmt, a.kind, b.kind, op1, op2, fpscr)) |result| return result;
    const inf1 = a.kind == .infinity;
    const inf2 = b.kind == .infinity;
    const zero1 = a.kind == .zero;
    const zero2 = b.kind == .zero;
    if ((inf1 and zero2) or (zero1 and inf2)) {
        fpscr.ioc = 1;
        return nan.defaultNaN(fmt);
    }
    const sign = a.sign ^ b.sign;
    if (inf1 or inf2) return fmt.infinity(sign);
    if (zero1 or zero2) return fmt.zero(sign);
    const product = format.Real{
        .sign = sign,
        .mant = a.real.mant * b.real.mant,
        .exp = a.real.exp + b.real.exp,
    };
    return round.round(fmt, product, fpscr, fpscr.rmode);
}

/// VNMUL: FPNeg(FPMul(op1, op2)).
pub fn nmul(comptime fmt: Format, op1: fmt.Bits(), op2: fmt.Bits(), fpscr: *Fpscr) fmt.Bits() {
    return mul(fmt, op1, op2, fpscr) ^ signBit(fmt);
}

pub fn signBit(comptime fmt: Format) fmt.Bits() {
    return @as(fmt.Bits(), 1) << @intCast(fmt.width() - 1);
}
