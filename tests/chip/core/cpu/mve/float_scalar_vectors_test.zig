//! Covers src/chip/core/cpu/mve/float_scalar_vectors.zig.
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const float_scalar = ra8.chip.core.cpu.mve.float_scalar;
const vectors = ra8.chip.core.cpu.mve.float_scalar_vectors;
const Out = ra8.chip.core.cpu.mve.float_vectors.Out;

fn run(in: vectors.Operands) Out {
    var fpscr: ra8.chip.core.cpu.fpu.fpscr.Fpscr = .{};
    const q: u128 = switch (in.op) {
        .add => float_scalar.binary(in.d, in.n, in.rm, in.size, .add, in.mask, &fpscr),
        .sub => float_scalar.binary(in.d, in.n, in.rm, in.size, .sub, in.mask, &fpscr),
        .mul => float_scalar.binary(in.d, in.n, in.rm, in.size, .mul, in.mask, &fpscr),
        .fma => float_scalar.fused(in.d, in.n, in.rm, in.size, .fma, in.mask, &fpscr),
        .fmas => float_scalar.fused(in.d, in.n, in.rm, in.size, .fmas, in.mask, &fpscr),
        .cmp => float_scalar.compare(in.n, in.rm, in.size, in.cond, in.mask, &fpscr),
    };
    return .{ .q = q, .flags = ra8.chip.core.cpu.fpu.case.flagsOf(fpscr) };
}

test "MVE floating-point by-scalar forms match the pseudocode" {
    try vector.expectAll(vectors.Operands, Out, run, &vectors.vectors);
}
