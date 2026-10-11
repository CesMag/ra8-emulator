//! Covers src/chip/core/cpu/mve/float/minmax/vectors.zig.
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const float_minmax = ra8.chip.core.cpu.mve.float.minmax;
const vectors = ra8.chip.core.cpu.mve.float.minmax.vectors;
const Out = ra8.chip.core.cpu.mve.float.vectors.Out;

fn run(in: vectors.Operands) Out {
    var fpscr: ra8.chip.core.cpu.fpu.fpscr.Fpscr = .{};
    const q = float_minmax.lanes(in.d, in.n, in.m, in.size, in.which, in.abs, in.mask, &fpscr);
    return .{ .q = q, .flags = ra8.chip.core.cpu.fpu.case.flagsOf(fpscr) };
}

test "MVE VMAXNM/VMINNM and the A forms match the pseudocode" {
    try vector.expectAll(vectors.Operands, Out, run, &vectors.vectors);
}
