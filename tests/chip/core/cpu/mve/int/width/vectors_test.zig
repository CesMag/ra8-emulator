//! Covers src/chip/core/cpu/mve/int_width_vectors.zig.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const int = ra8.chip.core.cpu.mve.int;
const width = ra8.chip.core.cpu.mve.int.width;
const vectors = ra8.chip.core.cpu.mve.int.width.vectors;

fn narrow(in: vectors.NarrowCase) int.Sat {
    return width.narrow(in.d, in.m, in.size, in.half, in.spec);
}

fn widen(in: vectors.WidenCase) u128 {
    return width.widen(in.m, in.size, in.half, in.unsigned, in.left);
}

test "the narrowing moves and shifts match the pseudocode" {
    try vector.expectAll(vectors.NarrowCase, int.Sat, narrow, &vectors.narrowing);
}

test "VMOVL and VSHLL match the pseudocode" {
    try vector.expectAll(vectors.WidenCase, u128, widen, &vectors.widening);
}

test "every vector is counted in covered" {
    try std.testing.expectEqual(vectors.narrowing.len + vectors.widening.len, vectors.covered.len);
}
