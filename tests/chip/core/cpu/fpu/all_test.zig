//! The FPU's share of the test root: every test file under
//! tests/chip/core/cpu/fpu/, pulled in by tests/all.zig, plus a check that every
//! export in src/chip/core/cpu/fpu/all.zig compiles.
const std = @import("std");
const ra8 = @import("ra8");

test {
    _ = @import("fpscr_test.zig");
    _ = @import("sign/sign_test.zig");
    _ = @import("sign/vectors_test.zig");
    _ = @import("format_test.zig");
    _ = @import("unpack_test.zig");
    _ = @import("round_test.zig");
    _ = @import("nan_test.zig");
    _ = @import("case_test.zig");
    _ = @import("add/add_test.zig");
    _ = @import("add/vectors_test.zig");
    _ = @import("mul/mul_test.zig");
    _ = @import("mul/vectors_test.zig");
    _ = @import("mac/mac_test.zig");
    _ = @import("mac/vectors_test.zig");
    _ = @import("fma/fma_test.zig");
    _ = @import("fma/vectors_test.zig");
    _ = @import("div/div_test.zig");
    _ = @import("div/vectors_test.zig");
    _ = @import("sqrt/sqrt_test.zig");
    _ = @import("sqrt/vectors_test.zig");
    _ = @import("compare/compare_test.zig");
    _ = @import("compare/vectors_test.zig");
    _ = @import("convert/convert_test.zig");
    _ = @import("convert/vectors_test.zig");
    _ = @import("to_int_test.zig");
    _ = @import("from_int_test.zig");
    _ = @import("int_vectors_test.zig");
    _ = @import("rounding_test.zig");
    _ = @import("directed_vectors_test.zig");
    _ = @import("rint/rint_test.zig");
    _ = @import("rint/vectors_test.zig");
    _ = @import("minmax/minmax_test.zig");
    _ = @import("minmax/vectors_test.zig");
    _ = @import("select/select_test.zig");
    _ = @import("select/vectors_test.zig");
    _ = @import("fixed/fixed_test.zig");
    _ = @import("fixed/vectors_test.zig");
    _ = @import("half/half_test.zig");
    _ = @import("half/vectors_test.zig");
    _ = @import("imm_test.zig");
    _ = @import("bank_test.zig");
    _ = @import("move_vectors_test.zig");
    _ = @import("transfer/transfer_test.zig");
    _ = @import("transfer/vectors_test.zig");
    _ = @import("state_test.zig");
    _ = @import("context_test.zig");
    _ = @import("scb_test.zig");
    _ = @import("lazy_test.zig");
    _ = @import("cpacr_test.zig");
    std.testing.refAllDecls(ra8.chip.core.cpu.fpu);
}
