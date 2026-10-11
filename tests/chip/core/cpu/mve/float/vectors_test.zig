//! Covers src/chip/core/cpu/mve/float/vectors.zig.
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const float = ra8.chip.core.cpu.mve.float;
const vectors = ra8.chip.core.cpu.mve.float.vectors;

fn run(in: vectors.Operands) vectors.Out {
    var fpscr: ra8.chip.core.cpu.fpu.fpscr.Fpscr = .{ .fz16 = in.fz16 };
    const q = float.binary(in.d, in.a, in.b, in.size, in.op, in.mask, &fpscr);
    return .{ .q = q, .flags = ra8.chip.core.cpu.fpu.case.flagsOf(fpscr) };
}

test "MVE VADD, VSUB and VMUL (floating-point) match the pseudocode" {
    try vector.expectAll(vectors.Operands, vectors.Out, run, &vectors.vectors);
}
