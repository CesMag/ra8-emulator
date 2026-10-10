//! The NPU model's path for a stream that is not the stand-in: read it from
//! QBASE, hand it to the Vela runner, and latch what happened in STATUS.
//!
//! npu.zig decodes the stand-in program and calls `kick` only when the
//! stream lacks the stand-in's marker, so the stand-in path and every image
//! that uses it are untouched. Results follow the same rules as the
//! stand-in: a completed program sets cmd_end and the interrupt; a stream
//! that cannot be read is a bus error; a stream that is malformed, or that
//! needs an operator this model does not run yet, is a parse fault. Every
//! fault raises the interrupt too, and cmd_end stays clear.
const std = @import("std");
const Guest = @import("../../core/cpu/memory/guest.zig").Guest;
const npu = @import("npu.zig");
const vela = @import("vela.zig");

/// The longest stream read in one kick: 4 KiB of commands.
pub const max_words = 1024;

/// What the Vela path did, kept apart from the stand-in's counters.
pub const Counters = struct {
    /// Programs that ran to their STOP.
    jobs: u32 = 0,
    /// Bytes those programs' DMA moved.
    moved: u64 = 0,
    /// Programs stopped at an operator this model does not run yet.
    unmodelled: u32 = 0,
    /// Streams that do not walk to a STOP, or a QSIZE that cannot hold one.
    malformed: u32 = 0,
    /// Kicks where the stream or a DMA could not reach memory.
    refused: u32 = 0,

    /// Every kick this path took, whether it ran to STOP or faulted.
    pub fn kicks(self: Counters) u32 {
        return self.jobs + self.faults();
    }

    /// The kicks that ended in a fault rather than a STOP.
    pub fn faults(self: Counters) u32 {
        return self.unmodelled + self.malformed + self.refused;
    }
};

fn reg64(unit: *const npu.Npu, low: u32) u64 {
    const lo = unit.reg[low / 4];
    const hi = unit.reg[(low + npu.geometry.hi_offset) / 4];
    return @as(u64, lo) | (@as(u64, hi) << 32);
}

/// BASEP0..7, the bus base of each region.
pub fn regions(unit: *const npu.Npu) vela.dma.Regions {
    var bases: vela.dma.Regions = undefined;
    for (&bases, 0..) |*base, index| {
        base.* = reg64(unit, npu.off.basep0 + @as(u32, @intCast(index)) * npu.geometry.basep_stride);
    }
    return bases;
}

fn fault(unit: *npu.Npu, bit: u32, counter: *u32) void {
    unit.state = bit | npu.field.status_irq;
    counter.* +%= 1;
    unit.due_irq = true;
}

/// Read QSIZE bytes at QBASE into `into`, or null if memory refused them.
fn readStream(memory: Guest, base: u32, into: []u32) ?void {
    for (into, 0..) |*word, index| {
        word.* = memory.readWord(base + @as(u32, @intCast(index)) * 4) catch return null;
    }
}

/// Run the stream at QBASE as a Vela program.
pub fn kick(unit: *npu.Npu, memory: Guest) void {
    const counters = &unit.vela;
    const base = reg64(unit, npu.off.qbase);
    const size = unit.reg[npu.off.qsize / 4];
    const count = size / 4;
    if (count == 0 or count > max_words or base + size > std.math.maxInt(u32)) {
        return fault(unit, npu.field.status_parse, &counters.malformed);
    }
    var buffer: [max_words]u32 = undefined;
    const words = buffer[0..count];
    readStream(memory, @intCast(base), words) orelse
        return fault(unit, npu.field.status_bus_error, &counters.refused);
    const bases = regions(unit);
    const result = vela.runner.run(memory, &bases, words) catch |why| return switch (why) {
        error.OperatorNotModelled => fault(unit, npu.field.status_parse, &counters.unmodelled),
        error.Refused => fault(unit, npu.field.status_bus_error, &counters.refused),
        else => fault(unit, npu.field.status_parse, &counters.malformed),
    };
    unit.state = npu.field.status_cmd_end | npu.field.status_irq;
    counters.jobs +%= 1;
    counters.moved +%= result.moved;
    unit.due_irq = true;
}
