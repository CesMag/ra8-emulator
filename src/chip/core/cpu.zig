//! The Zig CPU core (RA8EMU-10), as `ra8_chip.core.cpu`. The index file for
//! src/chip/core/cpu; its memory, exception model, FPU, MVE and disassembler
//! each have an index of their own.
pub const memory = @import("cpu/memory/all.zig");
pub const exception = @import("cpu/exception/all.zig");
pub const fpu = @import("cpu/fpu/all.zig");
pub const mve = @import("cpu/mve/all.zig");
pub const text = @import("cpu/text/all.zig");
pub const conformance_vector = @import("cpu/conformance/vector.zig");
pub const conformance_base = @import("cpu/conformance/base/all.zig");
pub const alignment = @import("cpu/alignment.zig");
pub const board_bus = @import("cpu/board_bus.zig");
pub const boot = @import("cpu/boot.zig");
pub const bus = @import("cpu/bus.zig");
pub const choice = @import("cpu/choice.zig");
pub const cond = @import("cpu/cond.zig");
pub const cortex = @import("cpu/cortex.zig");
pub const cpu = @import("cpu/cpu.zig");
pub const cpu_snapshot = @import("cpu/cpu_snapshot.zig");
pub const decode = @import("cpu/decode.zig");
pub const exclusive_peer = @import("cpu/exclusive_peer.zig");
pub const flags = @import("cpu/flags.zig");
pub const instr = @import("cpu/instr.zig");
pub const it_state = @import("cpu/it_state.zig");
pub const mapped = @import("cpu/memory/mapped.zig");
pub const op = @import("cpu/op.zig");
pub const ops = @import("cpu/ops.zig");
pub const regs = @import("cpu/regs.zig");
pub const reset = @import("cpu/reset.zig");
pub const scs_route = @import("cpu/scs_route.zig");
pub const shift = @import("cpu/shift.zig");
pub const sysreg = @import("cpu/sysreg.zig");
pub const thumb_imm = @import("cpu/thumb_imm.zig");
