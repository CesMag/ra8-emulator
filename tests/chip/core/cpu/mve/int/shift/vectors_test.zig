//! Covers src/chip/core/cpu/mve/int/shift/vectors.zig.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const int = ra8.chip.core.cpu.mve.int;
const shift = ra8.chip.core.cpu.mve.int.shift;
const vectors = ra8.chip.core.cpu.mve.int.shift.vectors;

fn byRegister(in: vectors.RegCase) int.Sat {
    return shift.byRegister(in.a, in.b, in.size, in.mode);
}

fn byImmediate(in: vectors.ImmCase) int.Sat {
    return shift.byImmediate(in.a, in.shift, in.size, in.mode);
}

test "VSHL, VRSHL, VQSHL and VQRSHL (register) match the pseudocode" {
    try vector.expectAll(vectors.RegCase, int.Sat, byRegister, &vectors.register);
}

test "VSHL, VSHR, VRSHR and VQSHL (immediate) match the pseudocode" {
    try vector.expectAll(vectors.ImmCase, int.Sat, byImmediate, &vectors.immediate);
}

test "every vector is counted in covered" {
    try std.testing.expectEqual(vectors.register.len + vectors.immediate.len, vectors.covered.len);
}
