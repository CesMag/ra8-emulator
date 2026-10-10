const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const fpu = ra8.chip.core.cpu.fpu;
const case = fpu.case;
const Fpscr = fpu.fpscr.Fpscr;
const vectors = fpu.move_vectors;

fn immSingle(in: case.Imm) case.Result(u32) {
    return .{ .bits = fpu.imm.expandImm(fpu.format.single, in.imm8) };
}

fn immDouble(in: case.Imm) case.Result(u64) {
    return .{ .bits = fpu.imm.expandImm(fpu.format.double, in.imm8) };
}

fn vmsr(in: case.Word) case.Result(u32) {
    return .{ .bits = Fpscr.fromBits(in.a).bits() };
}

fn vmrsNzcv(in: case.Word) case.Result(u32) {
    return .{ .bits = Fpscr.fromBits(in.a).apsrNzcv() };
}

test "VMOV.F32 (immediate) matches VFPExpandImm" {
    try vector.expectAll(case.Imm, case.Result(u32), immSingle, &vectors.imm_single);
}

test "VMOV.F64 (immediate) matches VFPExpandImm" {
    try vector.expectAll(case.Imm, case.Result(u64), immDouble, &vectors.imm_double);
}

test "VMSR keeps only the implemented FPSCR bits" {
    try vector.expectAll(case.Word, case.Result(u32), vmsr, &vectors.vmsr);
}

test "VMRS reads FPSCR back" {
    try vector.expectAll(case.Word, case.Result(u32), vmsr, &vectors.vmrs);
}

test "VMRS APSR_nzcv copies only the flags" {
    try vector.expectAll(case.Word, case.Result(u32), vmrsNzcv, &vectors.vmrs_nzcv);
}

test "every vector is counted in covered" {
    const n = vectors.imm_single.len + vectors.imm_double.len + vectors.vmsr.len + vectors.vmrs.len + vectors.vmrs_nzcv.len;
    try std.testing.expectEqual(n, vectors.covered.len);
}
