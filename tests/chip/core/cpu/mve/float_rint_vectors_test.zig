//! Covers src/chip/core/cpu/mve/float_rint_vectors.zig.
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance_vector;
const float_rint = ra8.chip.core.cpu.mve.float_rint;
const vectors = ra8.chip.core.cpu.mve.float_rint_vectors;
const Out = ra8.chip.core.cpu.mve.float_vectors.Out;

fn run(in: vectors.Operands) Out {
    var fpscr: ra8.chip.core.cpu.fpu.fpscr.Fpscr = .{};
    const q = float_rint.rint(in.d, in.m, in.size, in.kind, in.mask, &fpscr);
    return .{ .q = q, .flags = ra8.chip.core.cpu.fpu.case.flagsOf(fpscr) };
}

test "MVE VRINT matches the pseudocode" {
    try vector.expectAll(vectors.Operands, Out, run, &vectors.vectors);
}
