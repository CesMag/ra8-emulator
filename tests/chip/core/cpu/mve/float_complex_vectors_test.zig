//! Covers src/chip/core/cpu/mve/float_complex_vectors.zig.
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance_vector;
const float_complex = ra8.chip.core.cpu.mve.float_complex;
const vectors = ra8.chip.core.cpu.mve.float_complex_vectors;
const Out = ra8.chip.core.cpu.mve.float_vectors.Out;

fn run(in: vectors.Operands) Out {
    var fpscr: ra8.chip.core.cpu.fpu.fpscr.Fpscr = .{};
    const q = switch (in.op) {
        .cadd => float_complex.cadd(in.d, in.n, in.m, in.size, in.rot == 3, in.mask, &fpscr),
        .cmla => float_complex.cmla(in.d, in.n, in.m, in.size, in.rot, true, in.mask, &fpscr),
        .cmul => float_complex.cmla(in.d, in.n, in.m, in.size, in.rot, false, in.mask, &fpscr),
    };
    return .{ .q = q, .flags = ra8.chip.core.cpu.fpu.case.flagsOf(fpscr) };
}

test "MVE VCADD, VCMLA and VCMUL match the pseudocode" {
    try vector.expectAll(vectors.Operands, Out, run, &vectors.vectors);
}
