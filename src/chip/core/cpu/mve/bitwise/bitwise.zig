//! MVE vector bitwise operations from the Arm ARM (DDI0553) pseudocode
//! (RA8EMU-630): VAND, VBIC (register), VORR (register), VORN and VEOR.
//! Each works on the whole 128-bit vector at once; lane size does not
//! matter for a bitwise op. `vmov qd, qm` is VORR qd, qm, qm. Predication
//! and beats are applied by whoever writes the result back.

pub const Op = enum { @"and", bic, orr, orn, eor };

/// The result of `op` on vectors `a` (Qn) and `b` (Qm).
pub fn apply(a: u128, b: u128, op: Op) u128 {
    return switch (op) {
        .@"and" => a & b,
        .bic => a & ~b,
        .orr => a | b,
        .orn => a | ~b,
        .eor => a ^ b,
    };
}
