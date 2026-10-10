const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const fpu = ra8.chip.core.cpu.fpu;
const case = fpu.case;
const vectors = fpu.directed_vectors;

fn fromSingle(in: case.Directed(u32)) case.Result(u32) {
    var fpscr = in.fpscr();
    const bits = fpu.to_int.toFixedBy(fpu.format.single, in.a, 0, in.unsigned, in.rounding, &fpscr);
    return .{ .bits = bits, .flags = case.flagsOf(fpscr) };
}

fn fromDouble(in: case.Directed(u64)) case.Result(u32) {
    var fpscr = in.fpscr();
    const bits = fpu.to_int.toFixedBy(fpu.format.double, in.a, 0, in.unsigned, in.rounding, &fpscr);
    return .{ .bits = bits, .flags = case.flagsOf(fpscr) };
}

test "VCVTA/N/P/M from F32 match FPToFixed" {
    try vector.expectAll(case.Directed(u32), case.Result(u32), fromSingle, &vectors.from_single);
}

test "VCVTA/N/P/M from F64 match FPToFixed" {
    try vector.expectAll(case.Directed(u64), case.Result(u32), fromDouble, &vectors.from_double);
}

test "every vector is counted in covered" {
    try std.testing.expectEqual(vectors.from_single.len + vectors.from_double.len, vectors.covered.len);
}
