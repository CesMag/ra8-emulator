//! FPToFixed and FixedToFP from the Arm ARM (DDI0553) at the widths VCVT
//! (between floating point and fixed point) uses: a 16- or 32-bit integer
//! side and 1 to 32 fraction bits.
//!
//! To fixed point always rounds toward zero. A 16-bit result saturates at
//! 16 bits (IOC, and no IXC even if the value was also inexact) and comes
//! back sign- or zero-extended to 32 bits, as it lands in the register.
//! From fixed point reads only the low 16 bits of a 16-bit operand,
//! extended by signedness, and rounds under the given mode (FPSCR's).
const Format = @import("../format.zig").Format;
const RMode = @import("../fpscr.zig").RMode;
const Fpscr = @import("../fpscr.zig").Fpscr;
const to_int = @import("../to_int.zig");
const from_int = @import("../from_int.zig");
pub const vectors = @import("vectors.zig");

/// FPToFixed with `width` 16 or 32, rounding toward zero.
pub fn toFixed(comptime fmt: Format, op: fmt.Bits(), width: u6, fbits: u6, unsigned: bool, fpscr: *Fpscr) u32 {
    const before = fpscr.*;
    const word = to_int.toFixedBy(fmt, op, fbits, unsigned, .zero, fpscr);
    if (width == 32 or fitsHalf(word, unsigned)) return word;
    fpscr.ixc = before.ixc;
    fpscr.ioc = 1;
    return saturateHalf(word, unsigned);
}

/// FixedToFP with `width` 16 or 32, rounding under `mode`.
pub fn fromFixed(comptime fmt: Format, op: u32, width: u6, fbits: u6, unsigned: bool, mode: RMode, fpscr: *Fpscr) fmt.Bits() {
    const value = if (width == 32) op else widenHalf(op, unsigned);
    return from_int.fromFixed(fmt, value, fbits, unsigned, mode, fpscr);
}

fn fitsHalf(word: u32, unsigned: bool) bool {
    if (unsigned) return word <= 0xFFFF;
    const value: i32 = @bitCast(word);
    return value >= -0x8000 and value <= 0x7FFF;
}

fn saturateHalf(word: u32, unsigned: bool) u32 {
    if (unsigned) return 0xFFFF;
    const value: i32 = @bitCast(word);
    return if (value < 0) 0xFFFF_8000 else 0x7FFF;
}

fn widenHalf(op: u32, unsigned: bool) u32 {
    const half: u16 = @truncate(op);
    if (unsigned) return half;
    const signed: i16 = @bitCast(half);
    return @bitCast(@as(i32, signed));
}
