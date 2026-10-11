//! FPDiv from the Arm ARM (DDI0553), the arithmetic behind VDIV.
//!
//! NaN operands are handled first. Then 0/0 and inf/inf are invalid
//! (default NaN, IOC); a finite value over zero is an infinity with DZC,
//! while infinity over anything finite is an infinity with no flag; zero
//! over anything, or anything over infinity, is a zero. The sign of every
//! infinity and zero is the XOR of the operand signs. Everything else is the
//! quotient, rounded once by FPRound.
const format = @import("../format.zig");
const Format = format.Format;
const Real = format.Real;
const unpack_mod = @import("../unpack.zig");
const nan = @import("../nan.zig");
const round = @import("../round.zig");
const Fpscr = @import("../fpscr.zig").Fpscr;
pub const vectors = @import("vectors.zig");

/// The dividend is shifted until its top bit is this bit, so the quotient
/// of two mantissas of at most 53 bits keeps at least 73 bits.
pub const dividend_top: u7 = 126;

pub fn div(comptime fmt: Format, op1: fmt.Bits(), op2: fmt.Bits(), fpscr: *Fpscr) fmt.Bits() {
    const a = unpack_mod.unpack(fmt, op1, fpscr);
    const b = unpack_mod.unpack(fmt, op2, fpscr);
    if (nan.processNaNs(fmt, a.kind, b.kind, op1, op2, fpscr)) |result| return result;
    const inf1 = a.kind == .infinity;
    const inf2 = b.kind == .infinity;
    const zero1 = a.kind == .zero;
    const zero2 = b.kind == .zero;
    if ((inf1 and inf2) or (zero1 and zero2)) {
        fpscr.ioc = 1;
        return nan.defaultNaN(fmt);
    }
    const sign = a.sign ^ b.sign;
    if (inf1 or zero2) {
        if (!inf1) fpscr.dzc = 1;
        return fmt.infinity(sign);
    }
    if (zero1 or inf2) return fmt.zero(sign);
    return round.round(fmt, quotient(a.real, b.real), fpscr, fpscr.rmode);
}

/// x / y for nonzero mantissas: a long-enough integer quotient whose lowest
/// bit is set when the division left a remainder, so rounding sees it.
pub fn quotient(x: Real, y: Real) Real {
    const len: u8 = 128 - @as(u8, @clz(x.mant));
    const shift: u7 = @intCast(@as(u8, dividend_top) + 1 - len);
    const num = x.mant << shift;
    const q = num / y.mant;
    const r = num % y.mant;
    return .{
        .sign = x.sign ^ y.sign,
        .mant = q | @intFromBool(r != 0),
        .exp = x.exp - y.exp - @as(i32, shift),
    };
}
