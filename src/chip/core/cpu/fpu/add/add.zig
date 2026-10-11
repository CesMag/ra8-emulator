//! FPAdd and FPSub from the Arm ARM (DDI0553), the arithmetic behind VADD and
//! VSUB in single and double precision.
//!
//! NaN operands are handled first, on the operands as encoded, so FPSub
//! propagates a NaN second operand with its own sign. Then: infinities of
//! opposite effective sign are invalid (default NaN, IOC); any other infinity
//! wins; two zeros of the same effective sign keep it; and an exact zero sum
//! is +0, or -0 when rounding towards minus infinity. Everything else is the
//! exact sum, rounded once by FPRound.
const format = @import("../format.zig");
const Format = format.Format;
const Real = format.Real;
const unpack_mod = @import("../unpack.zig");
const Unpacked = unpack_mod.Unpacked;
const nan = @import("../nan.zig");
const round = @import("../round.zig");
const Fpscr = @import("../fpscr.zig").Fpscr;
pub const vectors = @import("vectors.zig");

/// How far apart two operands' exponents may be before the smaller one only
/// matters as a sticky bit. Past this the smaller operand is below a quarter
/// of the larger's last place, so a stand-in one unit at this distance rounds
/// identically, and the aligned sum still fits in 128 bits.
pub const align_limit: i32 = 72;

pub fn add(comptime fmt: Format, op1: fmt.Bits(), op2: fmt.Bits(), fpscr: *Fpscr) fmt.Bits() {
    return addSigned(fmt, op1, op2, 0, fpscr);
}

pub fn sub(comptime fmt: Format, op1: fmt.Bits(), op2: fmt.Bits(), fpscr: *Fpscr) fmt.Bits() {
    return addSigned(fmt, op1, op2, 1, fpscr);
}

fn addSigned(comptime fmt: Format, op1: fmt.Bits(), op2: fmt.Bits(), negate: u1, fpscr: *Fpscr) fmt.Bits() {
    const a = unpack_mod.unpack(fmt, op1, fpscr);
    var b = unpack_mod.unpack(fmt, op2, fpscr);
    if (nan.processNaNs(fmt, a.kind, b.kind, op1, op2, fpscr)) |result| return result;
    b.sign ^= negate;
    b.real.sign ^= negate;
    if (a.kind == .infinity and b.kind == .infinity and a.sign != b.sign) {
        fpscr.ioc = 1;
        return nan.defaultNaN(fmt);
    }
    if (a.kind == .infinity) return fmt.infinity(a.sign);
    if (b.kind == .infinity) return fmt.infinity(b.sign);
    if (a.kind == .zero and b.kind == .zero and a.sign == b.sign) return fmt.zero(a.sign);
    const sum = exactSum(term(a), term(b));
    if (sum.mant == 0) return fmt.zero(if (fpscr.rmode == .minus_inf) 1 else 0);
    return round.round(fmt, sum, fpscr, fpscr.rmode);
}

fn term(u: Unpacked) Real {
    if (u.kind == .zero) return .{ .sign = u.sign, .mant = 0, .exp = 0 };
    return u.real;
}

/// x + y exactly, or exactly enough that FPRound cannot tell the difference
/// (see `align_limit`). A zero mantissa in the result is an exact zero.
pub fn exactSum(x: Real, y: Real) Real {
    if (x.mant == 0) return y;
    if (y.mant == 0) return x;
    const hi = if (x.exp >= y.exp) x else y;
    var lo = if (x.exp >= y.exp) y else x;
    var d = hi.exp - lo.exp;
    if (d > align_limit) {
        lo = .{ .sign = lo.sign, .mant = 1, .exp = hi.exp - align_limit };
        d = align_limit;
    }
    const big = hi.mant << @intCast(d);
    if (hi.sign == lo.sign) return .{ .sign = hi.sign, .mant = big + lo.mant, .exp = lo.exp };
    if (big >= lo.mant) return .{ .sign = hi.sign, .mant = big - lo.mant, .exp = lo.exp };
    return .{ .sign = lo.sign, .mant = lo.mant - big, .exp = lo.exp };
}
