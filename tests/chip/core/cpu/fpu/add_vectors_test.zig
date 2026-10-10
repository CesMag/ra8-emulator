const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance_vector;
const format = ra8.chip.core.cpu.fpu.format;
const add = ra8.chip.core.cpu.fpu.add;
const case = ra8.chip.core.cpu.fpu.case;
const vectors = ra8.chip.core.cpu.fpu.add_vectors;

const In32 = case.Binary(u32);
const Out32 = case.Result(u32);
const In64 = case.Binary(u64);
const Out64 = case.Result(u64);

fn add32(in: In32) Out32 {
    var fpscr = in.fpscr();
    const bits = add.add(format.single, in.a, in.b, &fpscr);
    return .{ .bits = bits, .flags = case.flagsOf(fpscr) };
}

fn sub32(in: In32) Out32 {
    var fpscr = in.fpscr();
    const bits = add.sub(format.single, in.a, in.b, &fpscr);
    return .{ .bits = bits, .flags = case.flagsOf(fpscr) };
}

fn add64(in: In64) Out64 {
    var fpscr = in.fpscr();
    const bits = add.add(format.double, in.a, in.b, &fpscr);
    return .{ .bits = bits, .flags = case.flagsOf(fpscr) };
}

fn sub64(in: In64) Out64 {
    var fpscr = in.fpscr();
    const bits = add.sub(format.double, in.a, in.b, &fpscr);
    return .{ .bits = bits, .flags = case.flagsOf(fpscr) };
}

test "VADD.F32 matches FPAdd" {
    try vector.expectAll(In32, Out32, add32, &vectors.add32);
}

test "VSUB.F32 matches FPSub" {
    try vector.expectAll(In32, Out32, sub32, &vectors.sub32);
}

test "VADD.F64 matches FPAdd" {
    try vector.expectAll(In64, Out64, add64, &vectors.add64);
}

test "VSUB.F64 matches FPSub" {
    try vector.expectAll(In64, Out64, sub64, &vectors.sub64);
}

test "every vector is counted in covered" {
    const total = vectors.add32.len + vectors.sub32.len + vectors.add64.len + vectors.sub64.len;
    try std.testing.expectEqual(total, vectors.covered.len);
}
