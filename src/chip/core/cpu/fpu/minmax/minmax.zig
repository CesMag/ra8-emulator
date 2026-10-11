//! FPMaxNum and FPMinNum from the Arm ARM (DDI0553), the arithmetic behind
//! VMAXNM and VMINNM, with the FPMax and FPMin they build on.
//!
//! A single quiet NaN loses to the number: it is replaced by -inf for max
//! (+inf for min) before FPMax/FPMin runs. Any other NaN goes through
//! FPProcessNaNs as usual, so a signalling NaN still raises IOC and wins.
//! Operands are unpacked first (FZ flushes a denormal and sets IDC). -0 is
//! below +0: max of two zeros is -0 only when both are, min is -0 when
//! either is. Nothing is rounded except that a chosen finite value is
//! repacked through FPRound, which leaves it exact.
const format = @import("../format.zig");
const Format = format.Format;
const unpack_mod = @import("../unpack.zig");
const nan = @import("../nan.zig");
const round = @import("../round.zig");
const compare = @import("../compare/compare.zig");
const Fpscr = @import("../fpscr.zig").Fpscr;
pub const vectors = @import("vectors.zig");

pub const Which = enum { max, min };

/// FPMaxNum (`.max`) or FPMinNum (`.min`).
pub fn num(comptime fmt: Format, a: fmt.Bits(), b: fmt.Bits(), which: Which, fpscr: *Fpscr) fmt.Bits() {
    var scratch = fpscr.*;
    const ka = unpack_mod.unpack(fmt, a, &scratch).kind;
    const kb = unpack_mod.unpack(fmt, b, &scratch).kind;
    const fill = fmt.infinity(if (which == .max) 1 else 0);
    var x = a;
    var y = b;
    if (ka == .qnan and kb != .qnan) {
        x = fill;
    } else if (ka != .qnan and kb == .qnan) {
        y = fill;
    }
    return pick(fmt, x, y, which, fpscr);
}

/// FPMax (`.max`) or FPMin (`.min`).
pub fn pick(comptime fmt: Format, a: fmt.Bits(), b: fmt.Bits(), which: Which, fpscr: *Fpscr) fmt.Bits() {
    const ua = unpack_mod.unpack(fmt, a, fpscr);
    const ub = unpack_mod.unpack(fmt, b, fpscr);
    if (nan.processNaNs(fmt, ua.kind, ub.kind, a, b, fpscr)) |result| return result;
    const ka = compare.key(fmt, ua, a);
    const kb = compare.key(fmt, ub, b);
    const take_a = if (which == .max) ka > kb else ka < kb;
    const u = if (take_a) ua else ub;
    return switch (u.kind) {
        .infinity => fmt.infinity(u.sign),
        .zero => fmt.zero(if (which == .max) ua.sign & ub.sign else ua.sign | ub.sign),
        else => round.round(fmt, u.real, fpscr, fpscr.rmode),
    };
}
