const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance_vector;
const fpu = ra8.chip.core.cpu.fpu;
const case = fpu.case;
const vectors = fpu.compare_vectors;

const In32 = case.Compare(u32);
const In64 = case.Compare(u64);
const Out = case.Ordering;

fn compare32(in: In32) Out {
    var fpscr = in.fpscr();
    const nzcv = fpu.compare.compare(fpu.format.single, in.a, in.b, in.e == 1, &fpscr);
    return .{ .nzcv = nzcv, .flags = case.flagsOf(fpscr) };
}

fn compare64(in: In64) Out {
    var fpscr = in.fpscr();
    const nzcv = fpu.compare.compare(fpu.format.double, in.a, in.b, in.e == 1, &fpscr);
    return .{ .nzcv = nzcv, .flags = case.flagsOf(fpscr) };
}

test "VCMP and VCMPE .F32 match FPCompare" {
    try vector.expectAll(In32, Out, compare32, &vectors.compare32);
}

test "VCMP and VCMPE .F64 match FPCompare" {
    try vector.expectAll(In64, Out, compare64, &vectors.compare64);
}

test "every vector is counted in covered" {
    try std.testing.expectEqual(vectors.compare32.len + vectors.compare64.len, vectors.covered.len);
}
