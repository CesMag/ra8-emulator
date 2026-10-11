//! The M85 FPU semantics, one namespace so root.zig carries a single line
//! for them: pure functions over encoded operands and FPSCR, with their
//! conformance vectors.
pub const fpscr = @import("fpscr.zig");
pub const sign = @import("sign/sign.zig");
pub const format = @import("format.zig");
pub const unpack = @import("unpack.zig");
pub const round = @import("round.zig");
pub const nan = @import("nan.zig");
pub const case = @import("case.zig");
pub const add = @import("add/add.zig");
pub const mul = @import("mul/mul.zig");
pub const mac = @import("mac/mac.zig");
pub const fma = @import("fma/fma.zig");
pub const div = @import("div/div.zig");
pub const sqrt = @import("sqrt/sqrt.zig");
pub const compare = @import("compare/compare.zig");
pub const convert = @import("convert/convert.zig");
pub const to_int = @import("to_int.zig");
pub const from_int = @import("from_int.zig");
pub const int_vectors = @import("int_vectors.zig");
pub const rounding = @import("rounding.zig");
pub const directed_vectors = @import("directed_vectors.zig");
pub const rint = @import("rint/rint.zig");
pub const minmax = @import("minmax/minmax.zig");
pub const select = @import("select/select.zig");
pub const fixed = @import("fixed/fixed.zig");
pub const half = @import("half/half.zig");
pub const imm = @import("imm.zig");
pub const bank = @import("bank.zig");
pub const move_vectors = @import("move_vectors.zig");
pub const transfer = @import("transfer/transfer.zig");
pub const state = @import("state.zig");
pub const context = @import("context.zig");
pub const lazy = @import("lazy.zig");
pub const cpacr = @import("cpacr.zig");
pub const scb = @import("scb.zig");
