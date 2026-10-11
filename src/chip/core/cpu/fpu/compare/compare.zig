//! FPCompare from the Arm ARM (DDI0553), the arithmetic behind VCMP and
//! VCMPE. Both operands are unpacked first (so FZ flushes each denormal
//! and sets IDC), then any NaN makes the result unordered. A signalling
//! NaN always raises IOC; VCMPE raises it for a quiet NaN as well. Zeros
//! of either sign compare equal, and nothing is rounded.
const format = @import("../format.zig");
const Format = format.Format;
const unpack_mod = @import("../unpack.zig");
const Unpacked = unpack_mod.Unpacked;
const Fpscr = @import("../fpscr.zig").Fpscr;
pub const vectors = @import("vectors.zig");

/// The NZCV values FPCompare writes.
pub const nzcv = struct {
    pub const unordered: u4 = 0b0011;
    pub const equal: u4 = 0b0110;
    pub const less: u4 = 0b1000;
    pub const greater: u4 = 0b0010;
};

/// Compares a with b. `signal_qnan` is the VCMPE form.
pub fn compare(comptime fmt: Format, a: fmt.Bits(), b: fmt.Bits(), signal_qnan: bool, fpscr: *Fpscr) u4 {
    const ua = unpack_mod.unpack(fmt, a, fpscr);
    const ub = unpack_mod.unpack(fmt, b, fpscr);
    if (isNaN(ua) or isNaN(ub)) {
        if (signal_qnan or ua.kind == .snan or ub.kind == .snan) fpscr.ioc = 1;
        return nzcv.unordered;
    }
    const ka = key(fmt, ua, a);
    const kb = key(fmt, ub, b);
    if (ka == kb) return nzcv.equal;
    return if (ka < kb) nzcv.less else nzcv.greater;
}

fn isNaN(u: Unpacked) bool {
    return u.kind == .qnan or u.kind == .snan;
}

/// A signed integer with the same order as the value: the magnitude bits
/// already sort for a non-NaN, so only the sign has to be applied. A zero,
/// flushed denormals included, is 0 whatever its sign.
pub fn key(comptime fmt: Format, u: Unpacked, bits: fmt.Bits()) i128 {
    if (u.kind == .zero) return 0;
    const magnitude: i128 = bits & ~fmt.zero(1);
    return if (u.sign == 1) -magnitude else magnitude;
}
