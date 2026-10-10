//! The FPU's share of the test root: every test file under
//! tests/chip/core/cpu/fpu/, pulled in by tests/all.zig, plus a check that every
//! export in src/chip/core/cpu/fpu/all.zig compiles.
const std = @import("std");
const ra8 = @import("ra8");

test {
    _ = @import("fpscr_test.zig");
    _ = @import("sign_test.zig");
    _ = @import("sign_vectors_test.zig");
    _ = @import("format_test.zig");
    _ = @import("unpack_test.zig");
    _ = @import("round_test.zig");
    _ = @import("nan_test.zig");
    _ = @import("case_test.zig");
    _ = @import("add_test.zig");
    _ = @import("add_vectors_test.zig");
    _ = @import("mul_test.zig");
    _ = @import("mul_vectors_test.zig");
    _ = @import("mac_test.zig");
    _ = @import("mac_vectors_test.zig");
    _ = @import("fma_test.zig");
    _ = @import("fma_vectors_test.zig");
    _ = @import("div_test.zig");
    _ = @import("div_vectors_test.zig");
    _ = @import("sqrt_test.zig");
    _ = @import("sqrt_vectors_test.zig");
    _ = @import("compare_test.zig");
    _ = @import("compare_vectors_test.zig");
    _ = @import("convert_test.zig");
    _ = @import("convert_vectors_test.zig");
    _ = @import("to_int_test.zig");
    _ = @import("from_int_test.zig");
    _ = @import("int_vectors_test.zig");
    _ = @import("rounding_test.zig");
    _ = @import("directed_vectors_test.zig");
    _ = @import("rint_test.zig");
    _ = @import("rint_vectors_test.zig");
    _ = @import("minmax_test.zig");
    _ = @import("minmax_vectors_test.zig");
    _ = @import("select_test.zig");
    _ = @import("select_vectors_test.zig");
    _ = @import("fixed_test.zig");
    _ = @import("fixed_vectors_test.zig");
    _ = @import("half_test.zig");
    _ = @import("half_vectors_test.zig");
    _ = @import("imm_test.zig");
    _ = @import("bank_test.zig");
    _ = @import("move_vectors_test.zig");
    _ = @import("transfer_test.zig");
    _ = @import("transfer_vectors_test.zig");
    _ = @import("state_test.zig");
    _ = @import("context_test.zig");
    _ = @import("scb_test.zig");
    _ = @import("lazy_test.zig");
    _ = @import("cpacr_test.zig");
    std.testing.refAllDecls(ra8.chip.core.cpu.fpu);
}
