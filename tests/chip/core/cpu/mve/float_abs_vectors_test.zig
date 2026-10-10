//! Covers src/chip/core/cpu/mve/float_abs_vectors.zig.
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance_vector;
const float = ra8.chip.core.cpu.mve.float;
const vectors = ra8.chip.core.cpu.mve.float_abs_vectors;
const Out = ra8.chip.core.cpu.mve.float_vectors.Out;

fn run(in: vectors.Operands) Out {
    var fpscr: ra8.chip.core.cpu.fpu.fpscr.Fpscr = .{};
    const q = switch (in.kind) {
        .abd => float.binary(in.d, in.a, in.b, in.size, .abd, in.mask, &fpscr),
        .abs => float.unary(in.d, in.a, in.size, .abs, in.mask),
        .neg => float.unary(in.d, in.a, in.size, .neg, in.mask),
    };
    return .{ .q = q, .flags = ra8.chip.core.cpu.fpu.case.flagsOf(fpscr) };
}

test "MVE VABD, VABS and VNEG match the pseudocode" {
    try vector.expectAll(vectors.Operands, Out, run, &vectors.vectors);
}
