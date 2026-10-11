const std = @import("std");
const ra8 = @import("ra8");
const format = ra8.chip.core.cpu.fpu.format;
const fma = ra8.chip.core.cpu.fpu.fma;
const case = ra8.chip.core.cpu.fpu.case;
const vectors = ra8.chip.core.cpu.fpu.fma_vectors;

fn run(comptime fmt: format.Format, op: case.FusedOp, d: fmt.Bits(), n: fmt.Bits(), m: fmt.Bits(), fpscr: *ra8.chip.core.cpu.fpu.fpscr.Fpscr) fmt.Bits() {
    return switch (op) {
        .vfma => fma.vfma(fmt, d, n, m, fpscr),
        .vfms => fma.vfms(fmt, d, n, m, fpscr),
        .vfnma => fma.vfnma(fmt, d, n, m, fpscr),
        .vfnms => fma.vfnms(fmt, d, n, m, fpscr),
    };
}

fn expectVectors(comptime fmt: format.Format, vs: anytype) !void {
    for (vs) |v| {
        var fpscr = v.input.fpscr();
        const bits = run(fmt, v.input.op, v.input.d, v.input.n, v.input.m, &fpscr);
        const got = case.Result(fmt.Bits()){ .bits = bits, .flags = case.flagsOf(fpscr) };
        if (!std.meta.eql(got, v.expect)) {
            std.debug.print("{s} {s}: got {x} flags {x}, want {x} flags {x}\n", .{ v.encoding, v.name, got.bits, got.flags, v.expect.bits, v.expect.flags });
            return error.TestExpectedEqual;
        }
    }
}

test "VFMA.F32 matches FPMulAdd" {
    try expectVectors(format.single, &vectors.fma32);
}

test "VFMS, VFNMA and VFNMS .F32 match FPMulAdd with FPNeg" {
    try expectVectors(format.single, &vectors.others32);
}

test "the double-precision forms match" {
    try expectVectors(format.double, &vectors.all64);
}

test "every vector is counted in covered" {
    const total = vectors.fma32.len + vectors.others32.len + vectors.all64.len;
    try std.testing.expectEqual(total, vectors.covered.len);
}
