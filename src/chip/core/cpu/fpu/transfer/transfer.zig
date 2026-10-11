//! The address and register-list arithmetic of the FP loads and stores in
//! the Arm ARM (DDI0553): VLDR/VSTR, VLDM/VSTM and VPUSH/VPOP (VSTMDB and
//! VLDMIA on SP with writeback). Every form moves a run of consecutive S
//! words at consecutive addresses, D[n] being S[2n] then S[2n+1], so a plan
//! is just where the run starts in memory, which S it starts at, how many
//! words it has and what Rn becomes. Memory itself stays with the caller.
const Bank = @import("../bank.zig").Bank;
pub const vectors = @import("vectors.zig");

pub const Fault = enum { none, unpredictable, undefined };

pub const Plan = struct {
    fault: Fault = .none,
    start: u32 = 0,
    words: u8 = 0,
    first: u8 = 0,
    /// Rn after a writeback form, null when there is none.
    wback: ?u32 = null,
};

/// VLDM/VSTM fields, with d already assembled (Vd:D single, D:Vd double).
pub const Multiple = struct { p: u1, u: u1, w: u1, rn: u4, base: u32, d: u5, imm8: u8, double: bool };

/// VLDR/VSTR fields; for a PC base, `base` is the PC value the instruction
/// reads, which is word-aligned before use.
pub const Single = struct { u: u1, rn: u4, base: u32, d: u5, imm8: u8, double: bool, store: bool = false };

/// VLDM/VSTM (and VPUSH/VPOP). P == U with W set is UNDEFINED. Rn = PC, an
/// empty list, or a list past S31 (D15) is UNPREDICTABLE. An odd imm8 on
/// the double form (FLDMX/FSTMX) moves imm8/2 registers but still steps Rn
/// by imm8 words.
pub fn multiple(m: Multiple) Plan {
    if (m.p == m.u and m.w == 1) return .{ .fault = .undefined };
    if (m.p == 1 and m.w == 0) return .{ .fault = .undefined };
    if (m.rn == 15) return .{ .fault = .unpredictable };
    const regs: u32 = if (m.double) m.imm8 / 2 else m.imm8;
    const limit: u32 = if (m.double) 16 else 32;
    if (regs == 0 or m.d + regs > limit) return .{ .fault = .unpredictable };
    const imm32: u32 = @as(u32, m.imm8) << 2;
    const start = if (m.u == 1) m.base else m.base -% imm32;
    const after = if (m.u == 1) m.base +% imm32 else m.base -% imm32;
    return .{
        .start = start,
        .words = @intCast(if (m.double) regs * 2 else regs),
        .first = if (m.double) @as(u8, m.d) * 2 else m.d,
        .wback = if (m.w == 1) after else null,
    };
}

/// VLDR/VSTR. A PC base is Align(PC, 4) (the literal form); VSTR with a
/// PC base, and a D register past D15, are UNPREDICTABLE.
pub fn single(s: Single) Plan {
    if (s.store and s.rn == 15) return .{ .fault = .unpredictable };
    if (s.double and s.d >= 16) return .{ .fault = .unpredictable };
    const base = if (s.rn == 15) s.base & ~@as(u32, 3) else s.base;
    const imm32: u32 = @as(u32, s.imm8) << 2;
    return .{
        .start = if (s.u == 1) base +% imm32 else base -% imm32,
        .words = if (s.double) 2 else 1,
        .first = if (s.double) @as(u8, s.d) * 2 else s.d,
    };
}

/// A load: `memory` holds the plan's words read from start upward.
pub fn load(plan: Plan, bank: *Bank, memory: []const u32) void {
    for (memory[0..plan.words], 0..) |word, k| bank.s[plan.first + k] = word;
}

/// A store: fills `out` with the words to write from start upward.
pub fn store(plan: Plan, bank: *const Bank, out: []u32) void {
    for (out[0..plan.words], 0..) |*word, k| word.* = bank.s[plan.first + k];
}
