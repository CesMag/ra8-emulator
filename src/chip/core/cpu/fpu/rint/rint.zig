//! FPRoundInt from the Arm ARM (DDI0553), the arithmetic behind the VRINT
//! forms. The operand is unpacked (FZ flushes a denormal and sets IDC). A
//! NaN is processed; a zero or an infinity returns itself. Anything else
//! is rounded to an integral value as asked, and a zero result keeps the
//! operand's sign. Only VRINTX (`exact`) raises IXC when that rounding
//! changed the value.
const format = @import("../format.zig");
const Format = format.Format;
const unpack_mod = @import("../unpack.zig");
const nan = @import("../nan.zig");
const round = @import("../round.zig");
const rounding_mod = @import("../rounding.zig");
const Rounding = rounding_mod.Rounding;
const Fpscr = @import("../fpscr.zig").Fpscr;
pub const vectors = @import("vectors.zig");

pub fn rint(comptime fmt: Format, op: fmt.Bits(), rounding: Rounding, exact: bool, fpscr: *Fpscr) fmt.Bits() {
    const u = unpack_mod.unpack(fmt, op, fpscr);
    switch (u.kind) {
        .snan, .qnan => return nan.processNaN(fmt, u.kind, op, fpscr),
        .zero => return fmt.zero(u.sign),
        .infinity => return fmt.infinity(u.sign),
        .nonzero => {},
    }
    if (u.real.exp >= 0) return op;
    const cut = round.scale(u.real.mant, u.real.exp);
    const magnitude = cut.int + @intFromBool(rounding_mod.roundsUp(cut, u.sign, rounding));
    if (cut.err != .none and exact) fpscr.ixc = 1;
    if (magnitude == 0) return fmt.zero(u.sign);
    var ignored: Fpscr = .{};
    return round.round(fmt, .{ .sign = u.sign, .mant = magnitude, .exp = 0 }, &ignored, .zero);
}
