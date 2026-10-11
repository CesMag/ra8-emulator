//! Walking a real Vela command stream: which words are commands, which are
//! payloads, and what the program asks the NPU to do before it stops.
//!
//! This is the first step from the stand-in program in cmd.zig toward
//! running what Vela actually emits. Nothing executes here yet; the walk
//! only splits the stream into commands and counts the operations, so the
//! later slices (register state, DMA, the operators) have a decoded program
//! to work from.
//!
//! Encoding, from Arm's Vela 3.12.0 (Apache-2.0): ethos_u55_regs.py and
//! register_command_stream_generator.py. Each command word carries its
//! opcode in bits [9:0], its mode in bits [15:14] and a 16-bit parameter in
//! bits [31:16]. Mode 0 (cmd0) is the word alone; mode 1 (cmd1, 0x4000) is
//! followed by one 32-bit payload word. The other two modes are not emitted.
const std = @import("std");

/// What NPU_OP_DMA_START copies, kept beside the walk so root.zig stays one line.
pub const dma = @import("dma.zig");
/// The loop that runs a stream's register sets and DMA against memory.
pub const run = @import("run.zig");
/// What each cmd1 register set does to the register state.
pub const regs = @import("regs.zig");
/// How the NPU model hands a non-stand-in stream to the runner.
pub const hook = @import("hook.zig");
/// The IFM, IFM2 and OFM shape, precision and region registers.
pub const fm = @import("fm.zig");
/// The scale, activation and stride registers.
pub const quant = @import("quant.zig");
/// Element addresses and storage formats.
pub const addr = @import("addr.zig");
/// Elementwise MIN and MAX.
pub const minmax = @import("minmax.zig");
/// MAX pooling.
pub const pool = @import("pool.zig");
/// The per-channel scale-and-bias records a convolution reads.
pub const bias = @import("bias.zig");
/// The compressed weight stream a convolution reads.
pub const weights = @import("weights.zig");
/// The order a decoded weight stream walks the OHWI volume in.
pub const order = @import("order.zig");
/// OFM output scaling under the three rounding modes.
pub const round = @import("round.zig");
/// The int8 convolution datapath.
pub const conv = @import("conv.zig");
/// NPU_OP_CONV: the registers turned into a datapath call.
pub const convop = @import("convop.zig");
/// Elementwise MUL (NPU_OP_ELEMENTWISE mode 0).
pub const mul = @import("mul.zig");
pub const addsub = @import("addsub.zig");
/// AVERAGE pooling without padding.
pub const avgpool = @import("avgpool.zig");

pub const opcode_mask: u32 = 0x03FF;
pub const mode_mask: u32 = 0xC000;
pub const mode_payload32: u32 = 0x4000;
/// cmd0 register sets (NPU_SET_IFM_PAD_TOP 0x100 up to 0x18F in Vela's
/// `cmd0`): a register value in the parameter, no payload word.
pub const first_cmd0_set: u10 = 0x100;
pub const last_cmd0_set: u10 = 0x18F;

/// The cmd0 opcodes the Ethos-U55 defines (ethos_u55_regs.py `cmd0`).
pub const Op = enum(u10) {
    stop = 0x000,
    irq = 0x001,
    conv = 0x002,
    depthwise = 0x003,
    pool = 0x005,
    elementwise = 0x006,
    dma_start = 0x010,
    dma_wait = 0x011,
    kernel_wait = 0x012,
    pmu_mask = 0x013,
};

/// What a walk found in the program.
pub const Summary = struct {
    /// Words up to and including the STOP.
    words: usize = 0,
    /// cmd1 register writes, each with its payload.
    register_writes: usize = 0,
    /// cmd0 register sets, the value in the parameter.
    register_sets: usize = 0,
    conv: usize = 0,
    depthwise: usize = 0,
    pool: usize = 0,
    elementwise: usize = 0,
    dma_starts: usize = 0,
    waits: usize = 0,
    irqs: usize = 0,
    /// The STOP's 16-bit mask parameter.
    stop_mask: u16 = 0,

    /// Block operations the program runs (the operators, not the DMA).
    pub fn operations(self: Summary) usize {
        return self.conv + self.depthwise + self.pool + self.elementwise;
    }
};

pub const Error = error{ Truncated, UnknownMode, UnknownOpcode, NoStop };

/// The 16-bit parameter of a command word.
pub fn param(word: u32) u16 {
    return @truncate(word >> 16);
}

fn count(summary: *Summary, op: Op, word: u32) void {
    switch (op) {
        .stop => summary.stop_mask = param(word),
        .irq => summary.irqs += 1,
        .conv => summary.conv += 1,
        .depthwise => summary.depthwise += 1,
        .pool => summary.pool += 1,
        .elementwise => summary.elementwise += 1,
        .dma_start => summary.dma_starts += 1,
        .dma_wait, .kernel_wait => summary.waits += 1,
        .pmu_mask => {},
    }
}

/// Whether a cmd0 opcode sets a register rather than running something.
pub fn isCmd0Set(code: u10) bool {
    return code >= first_cmd0_set and code <= last_cmd0_set;
}

/// Walk `words` from the first command to the STOP.
pub fn walk(words: []const u32) Error!Summary {
    var summary = Summary{};
    var index: usize = 0;
    while (index < words.len) {
        const word = words[index];
        const mode = word & mode_mask;
        if (mode == mode_payload32) {
            if (index + 1 >= words.len) return error.Truncated;
            summary.register_writes += 1;
            index += 2;
            continue;
        }
        if (mode != 0) return error.UnknownMode;
        const code: u10 = @truncate(word & opcode_mask);
        index += 1;
        if (isCmd0Set(code)) {
            summary.register_sets += 1;
            continue;
        }
        const op = std.enums.fromInt(Op, code) orelse return error.UnknownOpcode;
        count(&summary, op, word);
        if (op == .stop) {
            summary.words = index;
            return summary;
        }
    }
    return error.NoStop;
}
