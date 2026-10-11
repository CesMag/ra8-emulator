//! Running a Vela command stream as far as this model can: the register
//! state it sets, and the DMA copies it starts.
//!
//! vela.zig checks the stream's shape, regs.zig keeps what the
//! cmd1 commands set, and dma.zig does one copy. This file is the
//! loop over them. Elementwise MIN and MAX run through minmax.zig,
//! elementwise MUL through mul.zig, ADD and SUB through
//! addsub.zig, MAX pooling through
//! pool.zig, unpadded AVERAGE pooling through
//! avgpool.zig, and int8 convolution and depthwise convolution
//! through convop.zig; any other block operation (other pool or
//! elementwise modes) stops the run with error.OperatorNotModelled, so
//! nothing that needs an unmodelled operator is reported as having run.
//! DMA0_SRC_REGION and _DST_REGION
//! (cmd0 0x130 and 0x131) pick the regions the next DMA_START copies
//! between; the feature-map sets go to fm.zig, the scale, activation
//! and stride sets to quant.zig, the kernel sets to
//! pool.zig, the weight region and OFM block depth to
//! convop.zig, and any other register set is passed over for now.
//! The convolution's scratch buffers come from the page allocator.
const std = @import("std");
const vela = @import("vela.zig");
const regs = @import("regs.zig");
const dma = @import("dma.zig");
const fm = @import("fm.zig");
const quant = @import("quant.zig");
const minmax = @import("minmax.zig");
const pool = @import("pool.zig");
const avgpool = @import("avgpool.zig");
const convop = @import("convop.zig");
const mul = @import("mul.zig");
const addsub = @import("addsub.zig");

pub const Error = vela.Error || dma.Error || minmax.Error || convop.Error;

pub const Result = struct {
    summary: vela.Summary,
    /// Bytes every DMA_START in the program moved, together.
    moved: u64 = 0,
    state: regs.State = .{},
    /// The feature-map registers as the program left them.
    maps: fm.State = .{},
    /// The scale, activation and stride registers as the program left them.
    quant: quant.State = .{},
    /// Output elements the elementwise operators wrote.
    elements: u64 = 0,
};

const Machine = struct {
    state: regs.State = .{},
    maps: fm.State = .{},
    quant: quant.State = .{},
    kernel: pool.State = .{},
    conv: convop.State = .{},
    src: dma.Region = .{},
    dst: dma.Region = .{},
    moved: u64 = 0,
    elements: u64 = 0,
};

fn setRegister(machine: *Machine, code: u10, word: u32) void {
    switch (code) {
        dma.set_dma0_src_region => machine.src = dma.Region.fromParam(vela.param(word)),
        dma.set_dma0_dst_region => machine.dst = dma.Region.fromParam(vela.param(word)),
        else => if (fm.apply(&machine.maps, code, vela.param(word)) == .not_modelled and
            quant.applyCmd0(&machine.quant, code, vela.param(word)) == .not_modelled)
        {
            if (pool.apply(&machine.kernel, code, vela.param(word)) == .not_modelled) {
                _ = convop.apply(&machine.conv, code, vela.param(word));
            }
        },
    }
}

fn operate(machine: *Machine, memory: anytype, regions: *const dma.Regions, op: vela.Op, word: u32) Error!void {
    switch (op) {
        .conv, .depthwise => machine.elements += try convop.run(std.heap.page_allocator, memory, regions, .{
            .bases = machine.state,
            .maps = machine.maps,
            .quant = machine.quant,
            .kernel = machine.kernel,
            .conv = machine.conv,
        }, op == .depthwise),
        .pool => {
            const inputs = pool.Inputs{ .bases = machine.state, .maps = machine.maps, .quant = machine.quant, .kernel = machine.kernel };
            const mode = vela.param(word);
            machine.elements += try if (mode == avgpool.mode_average) avgpool.run(memory, regions, inputs) else pool.run(memory, regions, mode, inputs);
        },
        .elementwise => {
            const inputs = minmax.Inputs{ .bases = machine.state, .maps = machine.maps, .quant = machine.quant };
            const mode = vela.param(word);
            machine.elements += try switch (mode) {
                mul.mode_mul => mul.run(memory, regions, inputs),
                addsub.mode_add, addsub.mode_sub => addsub.run(memory, regions, mode, inputs),
                else => minmax.run(memory, regions, mode, inputs),
            };
        },
        .dma_start => machine.moved += try dma.copy(memory, regions, machine.src, machine.dst, machine.state.dma0),
        .stop, .irq, .dma_wait, .kernel_wait, .pmu_mask => {},
    }
}

/// Run `words` to their STOP against `memory`, with `regions` as BASEP.
pub fn run(memory: anytype, regions: *const dma.Regions, words: []const u32) Error!Result {
    const summary = try vela.walk(words);
    var machine = Machine{};
    var index: usize = 0;
    while (index < summary.words) {
        const word = words[index];
        if (word & vela.mode_mask == vela.mode_payload32) {
            if (regs.apply(&machine.state, word, words[index + 1]) == .not_modelled) {
                const code: u10 = @truncate(word & vela.opcode_mask);
                _ = quant.applyCmd1(&machine.quant, code, vela.param(word), words[index + 1]);
            }
            index += 2;
            continue;
        }
        index += 1;
        const code: u10 = @truncate(word & vela.opcode_mask);
        if (vela.isCmd0Set(code)) {
            setRegister(&machine, code, word);
            continue;
        }
        // walk() already refused any opcode outside Op.
        try operate(&machine, memory, regions, @fromBackingInt(@intCast(code)), word);
    }
    return .{ .summary = summary, .moved = machine.moved, .state = machine.state, .maps = machine.maps, .quant = machine.quant, .elements = machine.elements };
}
