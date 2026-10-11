//! The Armv8.1-M scalar long shifts over a plain register file.
//!
//! These encodings sit in what Armv7-M
//! calls ORRS with a shifted register: Rm = PC for the immediate forms, Rm =
//! SP for the register forms. An Armv8.0-M model runs them as that ORRS, so the
//! high word of every 64-bit multiply-by-constant, offset or base the
//! compiler builds out of LSLL, LSRL or ASRL comes out as garbage.
//!
//! This file owns no semantics of its own. It asks the Zig core's four
//! decoders (src/chip/core/cpu/ops/long_shift*.zig) whether an encoding is
//! theirs and runs their arithmetic over a plain register file, so there
//! is one definition.
const Instr = @import("cpu/instr.zig").Instr;
const imm = @import("cpu/ops/long/shift/shift.zig");
const by_reg = @import("cpu/ops/long/shift/reg.zig");
const sat = @import("cpu/ops/long/shift/sat.zig");
const sat64 = @import("cpu/ops/long/shift/sat64.zig");

/// Every form is one 32-bit encoding.
pub const width: u32 = 4;

/// R0 to R14. No form reads or writes the PC.
pub const Regs = [15]u32;

pub const Form = union(enum) {
    imm: imm.Fields,
    by_reg: by_reg.Fields,
    sat: sat.Fields,
    sat64: sat64.Fields,
};

/// Which form this encoding is, or null when it is none of them.
pub fn decode(first: u16, second: u16) ?Form {
    const instr = Instr{ .address = 0, .hw1 = first, .hw2 = second, .size = width };
    if (imm.fields(instr)) |f| return .{ .imm = f };
    if (by_reg.fields(instr)) |f| return .{ .by_reg = f };
    if (sat.fields(instr)) |f| return .{ .sat = f };
    if (sat64.fields(instr)) |f| return .{ .sat64 = f };
    return null;
}

fn pair(regs: *const Regs, lo: u4, hi: u4) u64 {
    return (@as(u64, regs[hi]) << 32) | regs[lo];
}

fn setPair(regs: *Regs, lo: u4, hi: u4, value: u64) void {
    regs[lo] = @truncate(value);
    regs[hi] = @truncate(value >> 32);
}

/// Run one form over `regs`. Returns true when a saturating form clamped,
/// which is the caller's cue to set APSR.Q; no form touches N, Z, C or V.
pub fn run(form: Form, regs: *Regs) bool {
    switch (form) {
        .imm => |f| setPair(regs, f.lo, f.hi, imm.shift(f.kind, pair(regs, f.lo, f.hi), f.amount)),
        .by_reg => |f| {
            const amount: i8 = @bitCast(@as(u8, @truncate(regs[f.rm])));
            setPair(regs, f.lo, f.hi, by_reg.shift(f.kind, pair(regs, f.lo, f.hi), amount));
        },
        .sat => |f| {
            const r = sat.compute(f, regs[f.rda], if (f.rm) |m| regs[m] else 0);
            regs[f.rda] = r.value;
            return r.saturated;
        },
        .sat64 => |f| {
            const r = sat64.compute(f, pair(regs, f.lo, f.hi), if (f.rm) |m| regs[m] else 0);
            setPair(regs, f.lo, f.hi, r.value);
            return r.saturated;
        },
    }
    return false;
}
