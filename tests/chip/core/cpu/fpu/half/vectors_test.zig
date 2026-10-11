const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const fpu = ra8.chip.core.cpu.fpu;
const case = fpu.case;
const half = fpu.half;
const vectors = fpu.half.vectors;
const single = fpu.format.single;
const double = fpu.format.double;

fn fromSingle(in: case.Halves(u32)) case.Result(u32) {
    var fpscr = in.fpscr();
    const value = half.toHalf(single, in.a, &fpscr);
    return .{ .bits = half.place(in.d, value, in.top), .flags = case.flagsOf(fpscr) };
}

fn fromDouble(in: case.Halves(u64)) case.Result(u32) {
    var fpscr = in.fpscr();
    const value = half.toHalf(double, in.a, &fpscr);
    return .{ .bits = half.place(in.d, value, in.top), .flags = case.flagsOf(fpscr) };
}

fn toSingle(in: case.Halves(u32)) case.Result(u32) {
    var fpscr = in.fpscr();
    const bits = half.fromHalf(single, half.lane(in.a, in.top), &fpscr);
    return .{ .bits = bits, .flags = case.flagsOf(fpscr) };
}

fn toDouble(in: case.Halves(u32)) case.Result(u64) {
    var fpscr = in.fpscr();
    const bits = half.fromHalf(double, half.lane(in.a, in.top), &fpscr);
    return .{ .bits = bits, .flags = case.flagsOf(fpscr) };
}

test "VCVTB/VCVTT.F16.F32 match FPConvert" {
    try vector.expectAll(case.Halves(u32), case.Result(u32), fromSingle, &vectors.from_single);
}

test "VCVTB/VCVTT.F16.F64 match FPConvert" {
    try vector.expectAll(case.Halves(u64), case.Result(u32), fromDouble, &vectors.from_double);
}

test "VCVTB/VCVTT.F32.F16 match FPConvert" {
    try vector.expectAll(case.Halves(u32), case.Result(u32), toSingle, &vectors.to_single);
}

test "VCVTB/VCVTT.F64.F16 match FPConvert" {
    try vector.expectAll(case.Halves(u32), case.Result(u64), toDouble, &vectors.to_double);
}

fn expectLaneMatchesName(list: anytype) !void {
    for (list) |v| try std.testing.expectEqual(v.encoding[4] == 'T', v.input.top);
}

test "each vector's lane matches its B or T encoding" {
    try expectLaneMatchesName(&vectors.from_single);
    try expectLaneMatchesName(&vectors.from_double);
    try expectLaneMatchesName(&vectors.to_single);
    try expectLaneMatchesName(&vectors.to_double);
}

test "every vector is counted in covered" {
    const n = vectors.from_single.len + vectors.from_double.len + vectors.to_single.len + vectors.to_double.len;
    try std.testing.expectEqual(n, vectors.covered.len);
}
