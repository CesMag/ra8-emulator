//! Covers src/chip/core/cpu/mve/float/int/vectors.zig.
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const float_int = ra8.chip.core.cpu.mve.float.int;
const vectors = ra8.chip.core.cpu.mve.float.int.vectors;
const Out = ra8.chip.core.cpu.mve.float.vectors.Out;

fn run(in: vectors.Operands) Out {
    var fpscr: ra8.chip.core.cpu.fpu.fpscr.Fpscr = .{};
    const q = switch (in.dir) {
        .to_int => float_int.toInt(in.d, in.m, in.size, in.unsigned, in.rounding, in.fbits, in.mask, &fpscr),
        .from_int => float_int.fromInt(in.d, in.m, in.size, in.unsigned, in.fbits, in.mask, &fpscr),
    };
    return .{ .q = q, .flags = ra8.chip.core.cpu.fpu.case.flagsOf(fpscr) };
}

test "MVE VCVT between float and integer or fixed point matches the pseudocode" {
    try vector.expectAll(vectors.Operands, Out, run, &vectors.vectors);
}
