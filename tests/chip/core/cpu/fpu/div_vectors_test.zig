const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const format = ra8.chip.core.cpu.fpu.format;
const div = ra8.chip.core.cpu.fpu.div;
const case = ra8.chip.core.cpu.fpu.case;
const vectors = ra8.chip.core.cpu.fpu.div_vectors;

const In32 = case.Binary(u32);
const Out32 = case.Result(u32);
const In64 = case.Binary(u64);
const Out64 = case.Result(u64);

fn div32(in: In32) Out32 {
    var fpscr = in.fpscr();
    const bits = div.div(format.single, in.a, in.b, &fpscr);
    return .{ .bits = bits, .flags = case.flagsOf(fpscr) };
}

fn div64(in: In64) Out64 {
    var fpscr = in.fpscr();
    const bits = div.div(format.double, in.a, in.b, &fpscr);
    return .{ .bits = bits, .flags = case.flagsOf(fpscr) };
}

test "VDIV.F32 matches FPDiv" {
    try vector.expectAll(In32, Out32, div32, &vectors.div32);
}

test "VDIV.F64 matches FPDiv" {
    try vector.expectAll(In64, Out64, div64, &vectors.div64);
}

test "every vector is counted in covered" {
    try std.testing.expectEqual(vectors.div32.len + vectors.div64.len, vectors.covered.len);
}
