//! Covers src/chip/core/cpu/mve/float_fma_vectors.zig.
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const float = ra8.chip.core.cpu.mve.float;
const vectors = ra8.chip.core.cpu.mve.float_fma_vectors;
const Out = ra8.chip.core.cpu.mve.float_vectors.Out;

fn run(in: vectors.Operands) Out {
    var fpscr: ra8.chip.core.cpu.fpu.fpscr.Fpscr = .{};
    const q = float.fused(in.d, in.n, in.m, in.size, in.op, in.mask, &fpscr);
    return .{ .q = q, .flags = ra8.chip.core.cpu.fpu.case.flagsOf(fpscr) };
}

test "MVE VFMA, VFMS and VFMAS match the pseudocode" {
    try vector.expectAll(vectors.Operands, Out, run, &vectors.vectors);
}
