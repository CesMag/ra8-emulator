//! Covers src/chip/core/cpu/mve/modimm_vectors.zig.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const modimm = ra8.chip.core.cpu.mve.modimm;
const vectors = ra8.chip.core.cpu.mve.modimm.vectors;

fn run(in: vectors.Case) u128 {
    return modimm.run(in.op, in.cmode, in.imm8, in.qd).?;
}

test "VMOV, VMVN, VORR and VBIC (immediate) match the pseudocode" {
    try vector.expectAll(vectors.Case, u128, run, &vectors.vectors);
}

test "every vector is counted in covered" {
    try std.testing.expectEqual(vectors.vectors.len, vectors.covered.len);
}
