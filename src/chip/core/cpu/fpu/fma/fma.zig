//! FPMulAdd from the Arm ARM (DDI0553): addend + op1*op2 with a single
//! rounding, the arithmetic behind VFMA, VFMS, VFNMA and VFNMS.
//!
//! NaNs are processed across all three operands, addend first. A quiet NaN
//! addend with infinity times zero still gives the default NaN and IOC.
//! Infinity times zero, or an infinite addend against an infinite product of
//! the other sign, is invalid; any other infinity wins; zeros of the same
//! sign keep it; an exact zero sum is +0, or -0 under RM. Everything else is
//! the exact sum of the addend and the full product, rounded once.
const format = @import("../format.zig");
const Format = format.Format;
const Real = format.Real;
const unpack_mod = @import("../unpack.zig");
const Unpacked = unpack_mod.Unpacked;
const nan = @import("../nan.zig");
const round = @import("../round.zig");
const Fpscr = @import("../fpscr.zig").Fpscr;
pub const vectors = @import("vectors.zig");

/// An exact value wide enough for a double-precision product (106 bits)
/// aligned against an addend.
pub const Wide = struct { sign: u1, mant: u256, exp: i32 };

/// How many bits of a wide sum go on to FPRound; anything below them folds
/// into a sticky bit. Far more than the 55 rounding ever looks at.
pub const narrow_bits: u16 = 120;

pub fn mulAdd(comptime fmt: Format, addend: fmt.Bits(), op1: fmt.Bits(), op2: fmt.Bits(), fpscr: *Fpscr) fmt.Bits() {
    const a = unpack_mod.unpack(fmt, addend, fpscr);
    const x = unpack_mod.unpack(fmt, op1, fpscr);
    const y = unpack_mod.unpack(fmt, op2, fpscr);
    const inf_zero = (x.kind == .infinity and y.kind == .zero) or (x.kind == .zero and y.kind == .infinity);
    const kinds = [3]unpack_mod.Kind{ a.kind, x.kind, y.kind };
    if (nan.processNaNs3(fmt, kinds, .{ addend, op1, op2 }, fpscr)) |result| {
        if (a.kind == .qnan and inf_zero) return invalid(fmt, fpscr);
        return result;
    }
    const sign_p = x.sign ^ y.sign;
    const inf_p = x.kind == .infinity or y.kind == .infinity;
    const zero_p = x.kind == .zero or y.kind == .zero;
    if (inf_zero or (a.kind == .infinity and inf_p and a.sign != sign_p)) return invalid(fmt, fpscr);
    if (a.kind == .infinity) return fmt.infinity(a.sign);
    if (inf_p) return fmt.infinity(sign_p);
    if (a.kind == .zero and zero_p and a.sign == sign_p) return fmt.zero(a.sign);
    const product: Wide = if (zero_p)
        .{ .sign = sign_p, .mant = 0, .exp = 0 }
    else
        .{ .sign = sign_p, .mant = @as(u256, x.real.mant) * y.real.mant, .exp = x.real.exp + y.real.exp };
    const sum = exactSum(widen(a), product);
    if (sum.mant == 0) return fmt.zero(if (fpscr.rmode == .minus_inf) 1 else 0);
    return round.round(fmt, narrow(sum), fpscr, fpscr.rmode);
}

fn invalid(comptime fmt: Format, fpscr: *Fpscr) fmt.Bits() {
    fpscr.ioc = 1;
    return nan.defaultNaN(fmt);
}

fn widen(u: Unpacked) Wide {
    if (u.kind == .zero) return .{ .sign = u.sign, .mant = 0, .exp = 0 };
    return .{ .sign = u.real.sign, .mant = u.real.mant, .exp = u.real.exp };
}

/// One past the weight of the top set bit.
pub fn top(w: Wide) i32 {
    return w.exp + @as(i32, 256 - @as(i32, @clz(w.mant)));
}

/// x + y exactly, or exactly enough that FPRound cannot tell. When the
/// smaller term sits below both the larger term's last bit and a quarter
/// of the result's last place, any value in that range rounds the same, so
/// it becomes a one-unit stand-in there and the aligned sum stays narrow.
pub fn exactSum(x: Wide, y: Wide) Wide {
    if (x.mant == 0) return y;
    if (y.mant == 0) return x;
    const big = if (top(x) >= top(y)) x else y;
    var small = if (top(x) >= top(y)) y else x;
    const cut = @min(big.exp, top(big) - 57);
    if (top(small) <= cut - 1) small = .{ .sign = small.sign, .mant = 1, .exp = cut - 2 };
    const lo = @min(big.exp, small.exp);
    const bm = big.mant << @intCast(big.exp - lo);
    const sm = small.mant << @intCast(small.exp - lo);
    if (big.sign == small.sign) return .{ .sign = big.sign, .mant = bm + sm, .exp = lo };
    if (bm >= sm) return .{ .sign = big.sign, .mant = bm - sm, .exp = lo };
    return .{ .sign = small.sign, .mant = sm - bm, .exp = lo };
}

/// Fold a wide value to at most `narrow_bits` significant bits, keeping
/// whether anything below them was nonzero in the lowest bit.
pub fn narrow(w: Wide) Real {
    const len: i32 = 256 - @as(i32, @clz(w.mant));
    if (len <= narrow_bits) return .{ .sign = w.sign, .mant = @intCast(w.mant), .exp = w.exp };
    const k: u8 = @intCast(len - narrow_bits);
    const lost = w.mant & ((@as(u256, 1) << k) - 1);
    const kept = (w.mant >> k) | @intFromBool(lost != 0);
    return .{ .sign = w.sign, .mant = @intCast(kept), .exp = w.exp + k };
}

/// The four encodings, each FPMulAdd with FPNeg on its inputs.
pub fn vfma(comptime fmt: Format, d: fmt.Bits(), n: fmt.Bits(), m: fmt.Bits(), fpscr: *Fpscr) fmt.Bits() {
    return mulAdd(fmt, d, n, m, fpscr);
}

pub fn vfms(comptime fmt: Format, d: fmt.Bits(), n: fmt.Bits(), m: fmt.Bits(), fpscr: *Fpscr) fmt.Bits() {
    return mulAdd(fmt, d, neg(fmt, n), m, fpscr);
}

pub fn vfnma(comptime fmt: Format, d: fmt.Bits(), n: fmt.Bits(), m: fmt.Bits(), fpscr: *Fpscr) fmt.Bits() {
    return mulAdd(fmt, neg(fmt, d), neg(fmt, n), m, fpscr);
}

pub fn vfnms(comptime fmt: Format, d: fmt.Bits(), n: fmt.Bits(), m: fmt.Bits(), fpscr: *Fpscr) fmt.Bits() {
    return mulAdd(fmt, neg(fmt, d), n, m, fpscr);
}

fn neg(comptime fmt: Format, op: fmt.Bits()) fmt.Bits() {
    return op ^ (@as(fmt.Bits(), 1) << @intCast(fmt.width() - 1));
}
