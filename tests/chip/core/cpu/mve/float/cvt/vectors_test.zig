//! Covers src/chip/core/cpu/mve/float_cvt_vectors.zig.
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const float_cvt = ra8.chip.core.cpu.mve.float.cvt;
const vectors = ra8.chip.core.cpu.mve.float.cvt.vectors;
const Out = ra8.chip.core.cpu.mve.float.vectors.Out;

fn run(in: vectors.Operands) Out {
    var fpscr: ra8.chip.core.cpu.fpu.fpscr.Fpscr = .{ .ahp = in.ahp };
    const q = switch (in.dir) {
        .to_half => float_cvt.toHalf(in.d, in.m, in.top, in.mask, &fpscr),
        .from_half => float_cvt.fromHalf(in.d, in.m, in.top, in.mask, &fpscr),
    };
    return .{ .q = q, .flags = ra8.chip.core.cpu.fpu.case.flagsOf(fpscr) };
}

test "MVE VCVTB and VCVTT match the pseudocode" {
    try vector.expectAll(vectors.Operands, Out, run, &vectors.vectors);
}
