//! FPConvert to and from half precision from the Arm ARM (DDI0553), the
//! arithmetic behind VCVTB and VCVTT, plus the bottom/top lane placement
//! those two encodings differ by.
//!
//! The single or double operand is unpacked as usual (FZ flushes it and
//! sets IDC); a half operand or result is never flushed, following
//! FPUnpackCV and FPRoundCV. NaNs follow FPConvert: IOC when signalling,
//! the default NaN under DN, else FPConvertNaN. With FPSCR.AHP set the half
//! format has no infinities or NaNs: exponent 31 is an ordinary binade, a
//! NaN becomes a signed zero and an infinity or an overflow becomes the
//! largest magnitude, each with IOC and nothing else.
const format = @import("../format.zig");
const Real = format.Real;
const Format = format.Format;
const unpack_mod = @import("../unpack.zig");
const nan = @import("../nan.zig");
const round = @import("../round.zig");
const convertNaN = @import("../convert/convert.zig").convertNaN;
const Fpscr = @import("../fpscr.zig").Fpscr;
pub const vectors = @import("vectors.zig");
const half = format.half;

/// FPConvert from `from` into a half-precision value.
pub fn toHalf(comptime from: Format, op: from.Bits(), fpscr: *Fpscr) u16 {
    const u = unpack_mod.unpack(from, op, fpscr);
    switch (u.kind) {
        .snan, .qnan => {
            if (fpscr.ahp == 1) {
                fpscr.ioc = 1;
                return half.zero(u.sign);
            }
            if (u.kind == .snan) fpscr.ioc = 1;
            if (fpscr.dn == 1) return nan.defaultNaN(half);
            return convertNaN(from, half, op);
        },
        .zero => return half.zero(u.sign),
        .infinity => {
            if (fpscr.ahp == 0) return half.infinity(u.sign);
            fpscr.ioc = 1;
            return ahpMax(u.sign);
        },
        .nonzero => return if (fpscr.ahp == 1) roundAhp(u.real, fpscr) else roundIeee(u.real, fpscr),
    }
}

/// FPConvert from a half-precision value into `to`.
pub fn fromHalf(comptime to: Format, op: u16, fpscr: *Fpscr) to.Bits() {
    const sign: u1 = @intCast(op >> 15);
    if (fpscr.ahp == 1 and op >> 10 & 0x1F == 0x1F) {
        const real: Real = .{ .sign = sign, .mant = (op & 0x3FF) | 0x400, .exp = 16 - 10 };
        return round.round(to, real, fpscr, fpscr.rmode);
    }
    var unflushed: Fpscr = .{};
    const u = unpack_mod.unpack(half, op, &unflushed);
    switch (u.kind) {
        .snan, .qnan => {
            if (u.kind == .snan) fpscr.ioc = 1;
            if (fpscr.dn == 1) return nan.defaultNaN(to);
            return convertNaN(half, to, op);
        },
        .zero => return to.zero(sign),
        .infinity => return to.infinity(sign),
        .nonzero => return round.round(to, u.real, fpscr, fpscr.rmode),
    }
}

/// The half VCVTB (bottom) or VCVTT (top) reads from a register.
pub fn lane(word: u32, top: bool) u16 {
    return @truncate(if (top) word >> 16 else word);
}

/// `word` with its bottom or top half replaced, the other half kept.
pub fn place(word: u32, value: u16, top: bool) u32 {
    if (top) return (word & 0x0000_FFFF) | @as(u32, value) << 16;
    return (word & 0xFFFF_0000) | value;
}

/// FPRound into IEEE half precision, without FZ.
fn roundIeee(real: Real, fpscr: *Fpscr) u16 {
    var raised: Fpscr = .{ .rmode = fpscr.rmode };
    const bits = round.round(half, real, &raised, fpscr.rmode);
    fpscr.ofc |= raised.ofc;
    fpscr.ufc |= raised.ufc;
    fpscr.ixc |= raised.ixc;
    return bits;
}

/// FPRound into the alternative format. Values below 2^15 round exactly as
/// in IEEE half. Larger ones are rounded at half their size, where the
/// precision is the same, and moved up one binade into exponent 31.
fn roundAhp(real: Real, fpscr: *Fpscr) u16 {
    const top_exp = real.exp + 127 - @as(i32, @clz(real.mant));
    if (top_exp < 15) return roundIeee(real, fpscr);
    var halved = real;
    halved.exp -= 1;
    var raised: Fpscr = .{ .rmode = fpscr.rmode };
    const bits = round.round(half, halved, &raised, fpscr.rmode);
    if (raised.ofc == 1) {
        fpscr.ioc = 1;
        return ahpMax(real.sign);
    }
    fpscr.ixc |= raised.ixc;
    return bits + (1 << 10);
}

fn ahpMax(sign: u1) u16 {
    return @as(u16, sign) << 15 | 0x7FFF;
}
