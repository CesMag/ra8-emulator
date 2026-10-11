const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const format = ra8.chip.core.cpu.fpu.format;
const mac = ra8.chip.core.cpu.fpu.mac;
const case = ra8.chip.core.cpu.fpu.case;
const vectors = ra8.chip.core.cpu.fpu.mac_vectors;

const In32 = case.Ternary(u32);
const Out32 = case.Result(u32);
const In64 = case.Ternary(u64);
const Out64 = case.Result(u64);

fn run32(comptime op: anytype) fn (In32) Out32 {
    return struct {
        fn run(in: In32) Out32 {
            var fpscr = in.fpscr();
            const bits = op(format.single, in.d, in.n, in.m, &fpscr);
            return .{ .bits = bits, .flags = case.flagsOf(fpscr) };
        }
    }.run;
}

fn run64(comptime op: anytype, in: In64) Out64 {
    var fpscr = in.fpscr();
    const bits = op(format.double, in.d, in.n, in.m, &fpscr);
    return .{ .bits = bits, .flags = case.flagsOf(fpscr) };
}

test "VMLA.F32 matches FPAdd(d, FPMul)" {
    try vector.expectAll(In32, Out32, run32(mac.mla), &vectors.mla32);
}

test "VMLS.F32 matches FPAdd(d, FPNeg(FPMul))" {
    try vector.expectAll(In32, Out32, run32(mac.mls), &vectors.mls32);
}

test "VNMLA.F32 matches FPAdd(FPNeg(d), FPNeg(FPMul))" {
    try vector.expectAll(In32, Out32, run32(mac.nmla), &vectors.nmla32);
}

test "VNMLS.F32 matches FPAdd(FPNeg(d), FPMul)" {
    try vector.expectAll(In32, Out32, run32(mac.nmls), &vectors.nmls32);
}

test "the double-precision forms match, one vector each" {
    const ops = .{ mac.mla, mac.mls, mac.nmla, mac.nmls };
    inline for (ops, 0..) |op, i| {
        const v = vectors.all64[i];
        try std.testing.expectEqual(v.expect, run64(op, v.input));
    }
}

test "every vector is counted in covered" {
    const total = vectors.mla32.len + vectors.mls32.len + vectors.nmla32.len + vectors.nmls32.len + vectors.all64.len;
    try std.testing.expectEqual(total, vectors.covered.len);
}
