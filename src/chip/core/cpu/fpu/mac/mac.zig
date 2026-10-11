//! The chained multiply-accumulates from the Arm ARM (DDI0553): VMLA, VMLS,
//! VNMLA and VNMLS. Each is FPMul then FPAdd, two roundings, with FPNeg
//! applied to the product or the accumulator as the encoding asks. Flags
//! from both steps land in the same FPSCR, and FPNeg flips a NaN's sign like
//! any other value, so a NaN product or accumulator comes out negated.
const Format = @import("../format.zig").Format;
const add_mod = @import("../add/add.zig");
const mul_mod = @import("../mul/mul.zig");
const Fpscr = @import("../fpscr.zig").Fpscr;
pub const vectors = @import("vectors.zig");

/// VMLA: d + n*m.
pub fn mla(comptime fmt: Format, d: fmt.Bits(), n: fmt.Bits(), m: fmt.Bits(), fpscr: *Fpscr) fmt.Bits() {
    const product = mul_mod.mul(fmt, n, m, fpscr);
    return add_mod.add(fmt, d, product, fpscr);
}

/// VMLS: d + FPNeg(n*m).
pub fn mls(comptime fmt: Format, d: fmt.Bits(), n: fmt.Bits(), m: fmt.Bits(), fpscr: *Fpscr) fmt.Bits() {
    const product = mul_mod.mul(fmt, n, m, fpscr);
    return add_mod.add(fmt, d, neg(fmt, product), fpscr);
}

/// VNMLA: FPNeg(d) + FPNeg(n*m).
pub fn nmla(comptime fmt: Format, d: fmt.Bits(), n: fmt.Bits(), m: fmt.Bits(), fpscr: *Fpscr) fmt.Bits() {
    const product = mul_mod.mul(fmt, n, m, fpscr);
    return add_mod.add(fmt, neg(fmt, d), neg(fmt, product), fpscr);
}

/// VNMLS: FPNeg(d) + n*m.
pub fn nmls(comptime fmt: Format, d: fmt.Bits(), n: fmt.Bits(), m: fmt.Bits(), fpscr: *Fpscr) fmt.Bits() {
    const product = mul_mod.mul(fmt, n, m, fpscr);
    return add_mod.add(fmt, neg(fmt, d), product, fpscr);
}

fn neg(comptime fmt: Format, op: fmt.Bits()) fmt.Bits() {
    return op ^ mul_mod.signBit(fmt);
}
