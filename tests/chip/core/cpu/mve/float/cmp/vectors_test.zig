//! Covers src/chip/core/cpu/mve/float/cmp/vectors.zig.
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const float_cmp = ra8.chip.core.cpu.mve.float.cmp;
const vectors = ra8.chip.core.cpu.mve.float.cmp.vectors;

fn run(in: vectors.Operands) vectors.Out {
    var fpscr: ra8.chip.core.cpu.fpu.fpscr.Fpscr = .{ .fz16 = in.fz16 };
    const p0 = float_cmp.compare(in.n, in.m, in.size, in.cond, in.mask, &fpscr);
    return .{ .p0 = p0, .flags = ra8.chip.core.cpu.fpu.case.flagsOf(fpscr) };
}

test "MVE floating-point VCMP matches the pseudocode" {
    try vector.expectAll(vectors.Operands, vectors.Out, run, &vectors.vectors);
}
