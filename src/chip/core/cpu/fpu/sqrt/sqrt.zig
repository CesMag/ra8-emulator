//! FPSqrt from the Arm ARM (DDI0553), the arithmetic behind VSQRT.
//!
//! A NaN operand is processed (so a negative NaN still propagates, not
//! raises). A zero returns itself, sign included, and +inf returns +inf.
//! Any other negative operand, -inf among them, is invalid: default NaN and
//! IOC. Everything else is the square root, rounded once by FPRound. Under
//! FZ a negative denormal flushes to -0 first, so it returns -0, not a NaN.
const std = @import("std");
const format = @import("../format.zig");
const Format = format.Format;
const Real = format.Real;
const unpack_mod = @import("../unpack.zig");
const nan = @import("../nan.zig");
const round = @import("../round.zig");
const Fpscr = @import("../fpscr.zig").Fpscr;
pub const vectors = @import("vectors.zig");

/// The radicand is shifted until its top bit is at or just below this bit
/// (by an even amount), so the integer root keeps at least 62 bits.
pub const radicand_top: u8 = 126;

pub fn sqrt(comptime fmt: Format, op: fmt.Bits(), fpscr: *Fpscr) fmt.Bits() {
    const u = unpack_mod.unpack(fmt, op, fpscr);
    switch (u.kind) {
        .snan, .qnan => return nan.processNaN(fmt, u.kind, op, fpscr),
        .zero => return fmt.zero(u.sign),
        .infinity => if (u.sign == 0) return fmt.infinity(0),
        .nonzero => {},
    }
    if (u.sign == 1) {
        fpscr.ioc = 1;
        return nan.defaultNaN(fmt);
    }
    return round.round(fmt, root(u.real), fpscr, fpscr.rmode);
}

/// sqrt(x) for a positive nonzero value: the integer root of an evenly
/// scaled radicand, its lowest bit set when the root was not exact.
pub fn root(x: Real) Real {
    var mant = x.mant;
    var exp = x.exp;
    if (exp & 1 != 0) {
        mant <<= 1;
        exp -= 1;
    }
    const len: u8 = 128 - @as(u8, @clz(mant));
    const shift: u7 = @intCast((radicand_top - len) & ~@as(u8, 1));
    const radicand = mant << shift;
    const r: u128 = std.math.sqrt(radicand);
    const exact = r * r == radicand;
    return .{
        .sign = 0,
        .mant = r | @intFromBool(!exact),
        .exp = @divExact(exp - @as(i32, shift), 2),
    };
}
