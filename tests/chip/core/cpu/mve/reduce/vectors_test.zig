//! Covers src/chip/core/cpu/mve/reduce/vectors.zig.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const reduce = ra8.chip.core.cpu.mve.reduce;
const vectors = ra8.chip.core.cpu.mve.reduce.vectors;

fn addv(in: vectors.SumCase) u64 {
    return reduce.addv(@truncate(in.acc), in.a, in.size, in.unsigned);
}

fn addlv(in: vectors.SumCase) u64 {
    return reduce.addlv(in.acc, in.a, in.unsigned);
}

fn mladav(in: vectors.DotCase) u64 {
    return reduce.mladav(@truncate(in.acc), in.a, in.b, in.size, in.dual);
}

fn mlaldav(in: vectors.DotCase) u64 {
    return reduce.mlaldav(in.acc, in.a, in.b, in.size, in.dual);
}

test "VADDV matches the pseudocode" {
    try vector.expectAll(vectors.SumCase, u64, addv, &vectors.addv);
}

test "VADDLV matches the pseudocode" {
    try vector.expectAll(vectors.SumCase, u64, addlv, &vectors.addlv);
}

test "VMLADAV and VMLSDAV match the pseudocode" {
    try vector.expectAll(vectors.DotCase, u64, mladav, &vectors.mladav);
}

test "VMLALDAV and VMLSLDAV match the pseudocode" {
    try vector.expectAll(vectors.DotCase, u64, mlaldav, &vectors.mlaldav);
}

test "every vector is counted in covered" {
    const total = vectors.addv.len + vectors.addlv.len + vectors.mladav.len + vectors.mlaldav.len;
    try std.testing.expectEqual(total, vectors.covered.len);
}
