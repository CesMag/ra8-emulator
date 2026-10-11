//! The conformance suite: every encoding the Zig core's semantics claim, and
//! the encoding of every vector that covers one. Each semantics module
//! (src/chip/core/cpu/fpu/, src/chip/core/cpu/mve/ and the rest) exports a `claimed`
//! list and a `covered` list, and joins them here with `++`, so the coverage
//! table and the missing-vector check see the whole core at once.

const ra8 = @import("ra8");

/// Where the generated coverage table lives, relative to the build root.
pub const table_path = "tests/chip/core/cpu/conformance/coverage.md";

const fpu_sign = ra8.chip.core.cpu.fpu.sign.vectors;
const fpu_add = ra8.chip.core.cpu.fpu.add.vectors;
const fpu_mul = ra8.chip.core.cpu.fpu.mul.vectors;
const fpu_mac = ra8.chip.core.cpu.fpu.mac.vectors;
const fpu_fma = ra8.chip.core.cpu.fpu.fma.vectors;
const fpu_div = ra8.chip.core.cpu.fpu.div.vectors;
const fpu_sqrt = ra8.chip.core.cpu.fpu.sqrt.vectors;
const fpu_compare = ra8.chip.core.cpu.fpu.compare.vectors;
const fpu_convert = ra8.chip.core.cpu.fpu.convert.vectors;
const fpu_int = ra8.chip.core.cpu.fpu.int_vectors;
const fpu_directed = ra8.chip.core.cpu.fpu.directed_vectors;
const fpu_rint = ra8.chip.core.cpu.fpu.rint.vectors;
const fpu_minmax = ra8.chip.core.cpu.fpu.minmax.vectors;
const fpu_select = ra8.chip.core.cpu.fpu.select.vectors;
const fpu_fixed = ra8.chip.core.cpu.fpu.fixed.vectors;
const fpu_half = ra8.chip.core.cpu.fpu.half.vectors;
const fpu_move = ra8.chip.core.cpu.fpu.move_vectors;
const fpu_transfer = ra8.chip.core.cpu.fpu.transfer.vectors;
const mve_int = ra8.chip.core.cpu.mve.int.vectors;
const mve_shift = ra8.chip.core.cpu.mve.int.shift.vectors;
const mve_width = ra8.chip.core.cpu.mve.int.width.vectors;
const mve_insert = ra8.chip.core.cpu.mve.int.insert.vectors;
const mve_reduce = ra8.chip.core.cpu.mve.reduce.vectors;
const mve_mul = ra8.chip.core.cpu.mve.int.mul.vectors;
const mve_compare = ra8.chip.core.cpu.mve.compare.vectors;
const mve_minmax = ra8.chip.core.cpu.mve.reduce.minmax.vectors;
const mve_brsr = ra8.chip.core.cpu.mve.bit.reverse.vectors;
const mve_bitwise = ra8.chip.core.cpu.mve.bitwise.vectors;
const mve_modimm = ra8.chip.core.cpu.mve.modimm.vectors;
const mve_vldr = ra8.chip.core.cpu.mve.contiguous.vectors;
const mve_vldr_wide = ra8.chip.core.cpu.mve.contiguous.wide_vectors;
const mve_gather = ra8.chip.core.cpu.mve.gather.vectors;
const mve_gather64 = ra8.chip.core.cpu.mve.gather64_vectors;
const mve_gather_imm = ra8.chip.core.cpu.mve.gather.imm_vectors;
const mve_interleave = ra8.chip.core.cpu.mve.interleave.vectors;
const mve_memory_alignment = ra8.chip.core.cpu.mve.memory_alignment_vectors;
const mve_float = ra8.chip.core.cpu.mve.float.vectors;
const mve_float_fma = ra8.chip.core.cpu.mve.float.fma_vectors;
const mve_float_abs = ra8.chip.core.cpu.mve.float.abs_vectors;
const mve_float_cmp = ra8.chip.core.cpu.mve.float.cmp.vectors;
const mve_float_cvt = ra8.chip.core.cpu.mve.float.cvt.vectors;
const mve_float_int = ra8.chip.core.cpu.mve.float.int.vectors;
const mve_float_rint = ra8.chip.core.cpu.mve.float.rint.vectors;
const mve_float_minmax = ra8.chip.core.cpu.mve.float.minmax.vectors;
const mve_float_minmaxv = ra8.chip.core.cpu.mve.float.minmaxv_vectors;
const mve_float_complex = ra8.chip.core.cpu.mve.float.complex.vectors;
const mve_float_scalar = ra8.chip.core.cpu.mve.float.scalar.vectors;

pub const claimed: []const []const u8 = &(fpu_sign.claimed ++ fpu_add.claimed ++ fpu_mul.claimed ++ fpu_mac.claimed ++ fpu_fma.claimed ++ fpu_div.claimed ++ fpu_sqrt.claimed ++ fpu_compare.claimed ++ fpu_convert.claimed ++ fpu_int.claimed ++ fpu_directed.claimed ++ fpu_rint.claimed ++ fpu_minmax.claimed ++ fpu_select.claimed ++ fpu_fixed.claimed ++ fpu_half.claimed ++ fpu_move.claimed ++ fpu_transfer.claimed ++ mve_int.claimed ++ mve_shift.claimed ++ mve_width.claimed ++ mve_insert.claimed ++ mve_reduce.claimed ++ mve_mul.claimed ++ mve_compare.claimed ++ mve_minmax.claimed ++ mve_brsr.claimed ++ mve_bitwise.claimed ++ mve_modimm.claimed ++ mve_vldr.claimed ++ mve_vldr_wide.claimed ++ mve_gather.claimed ++ mve_gather64.claimed ++ mve_gather_imm.claimed ++ mve_interleave.claimed ++ mve_float.claimed ++ mve_float_fma.claimed ++ mve_float_abs.claimed ++ mve_float_cmp.claimed ++ mve_float_cvt.claimed ++ mve_float_int.claimed ++ mve_float_rint.claimed ++ mve_float_minmax.claimed ++ mve_float_minmaxv.claimed ++ mve_float_complex.claimed ++ mve_float_scalar.claimed);

pub const covered: []const []const u8 = &(fpu_sign.covered ++ fpu_add.covered ++ fpu_mul.covered ++ fpu_mac.covered ++ fpu_fma.covered ++ fpu_div.covered ++ fpu_sqrt.covered ++ fpu_compare.covered ++ fpu_convert.covered ++ fpu_int.covered ++ fpu_directed.covered ++ fpu_rint.covered ++ fpu_minmax.covered ++ fpu_select.covered ++ fpu_fixed.covered ++ fpu_half.covered ++ fpu_move.covered ++ fpu_transfer.covered ++ mve_int.covered ++ mve_shift.covered ++ mve_width.covered ++ mve_insert.covered ++ mve_reduce.covered ++ mve_mul.covered ++ mve_compare.covered ++ mve_minmax.covered ++ mve_brsr.covered ++ mve_bitwise.covered ++ mve_modimm.covered ++ mve_vldr.covered ++ mve_vldr_wide.covered ++ mve_gather.covered ++ mve_gather64.covered ++ mve_gather_imm.covered ++ mve_interleave.covered ++ mve_memory_alignment.covered ++ mve_float.covered ++ mve_float_fma.covered ++ mve_float_abs.covered ++ mve_float_cmp.covered ++ mve_float_cvt.covered ++ mve_float_int.covered ++ mve_float_rint.covered ++ mve_float_minmax.covered ++ mve_float_minmaxv.covered ++ mve_float_complex.covered ++ mve_float_scalar.covered);

/// The group named by every decode-table vector (RA8EMU-270). The coverage
/// table lists every group src/chip/core/cpu/ops/table.zig registers, with or
/// without vectors; the per-group vector files under base/ fill it
/// (RA8EMU-278, 279, 280). The group names themselves are read
/// from the table by the suite test, since evaluating the table from here
/// would loop through the core's types.
pub const decoded_covered: []const []const u8 = base.covered;

/// The per-group base vectors, one file per decode-table group.
pub const base = ra8.chip.core.cpu.conformance.base;
