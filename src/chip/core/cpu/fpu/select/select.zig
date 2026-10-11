//! VSEL from the Arm ARM (DDI0553): pick one of two registers on a
//! condition over the APSR flags. The encoding's two cc bits name EQ, VS,
//! GE or GT. The chosen value is moved as raw bits, so a NaN, signalling
//! or not, passes through untouched and no FPSCR flag is ever raised.

/// The four conditions VSEL encodes, by their cc field.
pub const Cond = enum(u2) { eq = 0b00, vs = 0b01, ge = 0b10, gt = 0b11 };

/// ConditionPassed for a VSEL condition. `nzcv` holds N in bit 3, then Z,
/// C, and V in bit 0.
pub fn passed(cond: Cond, nzcv: u4) bool {
    const n = nzcv >> 3 & 1;
    const z = nzcv >> 2 & 1;
    const v = nzcv & 1;
    return switch (cond) {
        .eq => z == 1,
        .vs => v == 1,
        .ge => n == v,
        .gt => z == 0 and n == v,
    };
}

/// The VSEL result: `a` (Sn/Dn) when the condition holds, else `b`.
pub fn select(comptime B: type, cond: Cond, nzcv: u4, a: B, b: B) B {
    return if (passed(cond, nzcv)) a else b;
}
