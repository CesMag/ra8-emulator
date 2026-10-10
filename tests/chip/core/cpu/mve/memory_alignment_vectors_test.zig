//! Covers src/chip/core/cpu/mve/memory_alignment_vectors.zig.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const alignment = ra8.chip.core.cpu.mve.memory_alignment_vectors;

test "MVE memory alignment vectors match MemA" {
    try vector.expectAll(alignment.Access, bool, alignment.isAligned, &alignment.vectors);
}

test "every MVE memory alignment vector names a claimed encoding" {
    try std.testing.expectEqual(alignment.vectors.len, alignment.covered.len);
}
