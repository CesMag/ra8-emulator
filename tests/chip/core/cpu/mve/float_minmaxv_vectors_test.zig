//! Covers src/chip/core/cpu/mve/float_minmaxv_vectors.zig.
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const float_minmax = ra8.chip.core.cpu.mve.float_minmax;
const vectors = ra8.chip.core.cpu.mve.float_minmaxv_vectors;

fn run(in: vectors.Operands) vectors.Out {
    var fpscr: ra8.chip.core.cpu.fpu.fpscr.Fpscr = .{};
    const r = float_minmax.reduce(in.ra, in.m, in.size, in.which, in.abs, in.mask, &fpscr);
    return .{ .r = r, .flags = ra8.chip.core.cpu.fpu.case.flagsOf(fpscr) };
}

test "MVE VMAXNMV/VMINNMV and the AV forms match the pseudocode" {
    try vector.expectAll(vectors.Operands, vectors.Out, run, &vectors.vectors);
}
