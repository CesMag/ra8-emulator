//! DMAC0: the direct memory access controller, which copies a buffer on one
//! register store instead of a loop of loads and stores.
//!
//! Eight channels at 0x4000_A000, 0x40 apart. The shared module bank next
//! door, whose DMAST.DMST is the activation gate over all eight, is its own
//! file (dma_bank.zig) and this block asks it before every request. A channel is programmed with DMSAR, DMDAR, DMCRA, DMCRB, DMTMD
//! and DMAMD, armed with DMCNT.DTE, and triggered with a DMREQ.SWREQ store.
//! Unlike the DTC next door, nothing about the transfer lives in memory: the
//! registers ARE the descriptor, which is why there is no vector table here.
//!
//! Ported from board_periph_dmac.c on dev, with four of its behaviours
//! corrected rather than carried over, each named in the decisions below: dev
//! copies the whole count on one request whatever DMREQ.CLRS says, ignores
//! DMAST entirely, leaves DMCNT.DTE up after the count is spent, and treats
//! every address mode that is not increment as fixed.
//!
//! ONE DIVERGENCE OF THIS TREE'S OWN, SAID OUT LOUD: the copy happens inside
//! the SWREQ store, as it does on dev, but the transfer-end interrupt does
//! not: it is queued and raised at the chunk boundary with the rest of the
//! events, so firmware sees the bytes immediately and the interrupt one
//! boundary later.
const std = @import("std");
const Bounded = @import("../../core/bounded.zig").Bounded;

const Guest = @import("../../core/cpu/memory/guest/guest.zig").Guest;
const dma_bank = @import("../dma_bank.zig");
const lanes = @import("../lanes.zig");
const periph = @import("../registry.zig");
pub const regs = @import("regs.zig");
pub const xfer = @import("xfer.zig");

/// DMAC0 channel geometry (ra8_dmac_regs.h).
pub const win_base: u32 = 0x4000_A000;
pub const channel_stride: u32 = 0x40;
pub const channel_count: usize = 8;
pub const win_span: u32 = channel_stride * @as(u32, channel_count);

/// DMAC0 channel-0 transfer-end event; the eight channels run from there.
pub const event_base: u16 = 0x0E0;

/// The register map of one channel, and the lanes each register occupies,
/// live in src/chip/periph/dmac/regs.zig. They are re-exported here because a
/// channel's window is what most callers mean by "the DMAC".
pub const off = regs.off;
pub const field = regs.field;

/// A ceiling on one continuous request, so a mis-programmed channel stops
/// instead of walking the whole address space.
pub const max_units: u32 = 0x1_0000;

/// Why a request moved nothing. Every one of these reads back to the firmware
/// as a channel that simply did not transfer, so they are counted and
/// reported rather than passed over.
pub const Refusal = union(enum) {
    /// DMAST.DMST is clear: the module was never started, so no channel
    /// transfers. dev shadows DMAST and copies anyway.
    stopped,
    /// DMCNT.DTE is clear, which is also what a finished channel looks like.
    disarmed,
    /// The count is spent and the channel was not re-armed.
    spent,
    /// No engine behind the board, which only a test builds.
    unbacked,
    /// A channel shape this model will not invent a transfer for.
    unsupported: xfer.Unsupported,
};

pub fn refusalName(reason: Refusal) []const u8 {
    return switch (reason) {
        .unsupported => |detail| @tagName(detail),
        else => @tagName(reason),
    };
}

pub const Due = Bounded(u16, channel_count);

/// A channel's two running counts, taken together so they can be put back as
/// they stood.
pub const Counts = struct {
    /// Units left in the current block.
    pending: u32,
    /// Blocks left.
    blocks: u32,
};

/// One channel: its registers, the counts it latched when it was armed, and
/// what it has moved.
pub const Channel = struct {
    dmsar: u32 = 0,
    dmdar: u32 = 0,
    dmcra: u32 = 0,
    dmcrb: u32 = 0,
    dmofr: u32 = 0,
    dmtmd: u16 = 0,
    dmamd: u16 = 0,
    dmint: u8 = 0,
    dmcnt: u8 = 0,
    dmsts: u8 = 0,
    /// Units left in the current block, latched from DMCRAL when DTE went up.
    pending: u32 = 0,
    /// Blocks left, latched from DMCRB.
    blocks: u32 = 0,
    requests: u32 = 0,
    units: u64 = 0,
    bytes: u64 = 0,
    completions: u32 = 0,
    /// Requests a memory fault cut short before the last of their units.
    faults: u32 = 0,

    pub fn armed(self: *const Channel) bool {
        return self.dmcnt & field.dte != 0;
    }

    pub fn plan(self: *const Channel) xfer.Plan {
        return xfer.Plan.decode(self.dmtmd, self.dmamd);
    }

    pub fn quiet(self: *const Channel) bool {
        return self.requests == 0 and !self.armed();
    }

    /// DMCNT.DTE going up loads the counts, the way silicon does: a channel
    /// whose count is spent has to be re-armed before it moves again.
    pub fn arm(self: *Channel) void {
        self.pending = xfer.latchedCount(self.dmcra);
        self.blocks = xfer.latchedBlocks(self.dmcrb);
    }

    /// The counts as they stand, so a request memory cuts short can put back
    /// what it was going to pay for and never moved.
    pub fn latched(self: *const Channel) Counts {
        return .{ .pending = self.pending, .blocks = self.blocks };
    }

    pub fn relatch(self: *Channel, saved: Counts) void {
        self.pending = saved.pending;
        self.blocks = saved.blocks;
    }

    /// Spend one request's worth of counts and answer the units it is worth.
    fn spend(self: *Channel, shape: xfer.Plan) u32 {
        if (shape.mode != .block) {
            self.pending -= 1;
            return 1;
        }
        const size = @min(xfer.blockSize(self.dmcra), max_units);
        self.blocks -= 1;
        if (self.blocks == 0) self.pending = 0;
        return size;
    }

    fn done(self: *const Channel, shape: xfer.Plan) bool {
        return if (shape.mode == .block) self.blocks == 0 else self.pending == 0;
    }
};

/// The eight channels, the module gate over them, and the counters behind the
/// end-of-run line.
pub const Dmac = struct {
    channels: [channel_count]Channel = @splat(.{}),
    /// The machine whose memory a transfer moves. wiring.attachBlocks points
    /// this at the run's guest memory; a board built without one declines
    /// every request.
    memory: ?Guest = null,
    /// The module bank next door, whose DMAST.DMST gates every channel.
    /// wiring.attachBlocks points this at the board's own bank, not a copy.
    bank: *const dma_bank.Bank,
    due: Due = Due{},
    refused: u32 = 0,
    last_refusal: ?Refusal = null,

    pub fn init(bank: *const dma_bank.Bank) Dmac {
        return .{ .bank = bank };
    }

    pub fn started(self: *const Dmac) bool {
        return self.bank.started();
    }

    pub fn quiet(self: *const Dmac) bool {
        if (self.refused != 0 or self.started()) return false;
        for (&self.channels) |*channel| {
            if (!channel.quiet()) return false;
        }
        return true;
    }

    /// The transfer-end interrupts this boundary, drained by the board.
    pub fn dueEvents(self: *Dmac) Due {
        const ready = self.due;
        self.due = Due{};
        return ready;
    }

    /// One software transfer request on a channel. With DMREQ.CLRS clear the
    /// request is worth ONE transfer and clears itself, which is the line dev
    /// gets wrong; with CLRS set it stays asserted and the count drains.
    pub fn request(self: *Dmac, index: usize, continuous: bool) void {
        const shape = self.channels[index].plan();
        if (!self.started()) return self.refuse(.stopped);
        if (!self.channels[index].armed()) return self.refuse(.disarmed);
        if (shape.unsupported()) |reason| return self.refuse(.{ .unsupported = reason });
        if (self.channels[index].pending == 0) return self.refuse(.spent);
        if (self.memory == null) return self.refuse(.unbacked);
        self.channels[index].dmsts |= field.act;
        while (true) {
            // A continuous request drains the count, but not over an address
            // memory has just refused: that walks the rest of the count into
            // the same wall one unit at a time.
            if (self.transfer(index, shape)) break;
            if (!continuous or self.channels[index].done(shape)) break;
        }
        self.settle(index, shape);
    }

    /// One request's worth of units, with the addresses and the running count
    /// left where they now stand so a polling driver sees progress. Answers
    /// whether memory cut the request short of the units it asked for.
    ///
    /// A SHORT REQUEST PAYS FOR NOTHING. The units that reached the
    /// destination stay there and the addresses stand over them, but the
    /// counts go back as they were, because this request did not deliver what
    /// they were spent on. That is also what keeps the channel from claiming
    /// it finished: settle() only takes DTE down and raises DTIF once the
    /// counts are done, and counts that were put back are not. Same rule
    /// dtc.zig takes for a block that ran off the end of memory.
    fn transfer(self: *Dmac, index: usize, shape: xfer.Plan) bool {
        const channel = &self.channels[index];
        const saved = channel.latched();
        const units = @min(channel.spend(shape), max_units);
        const moved = self.copy(channel, shape, units);
        channel.requests +%= 1;
        channel.units += moved;
        channel.bytes += moved * shape.unit();
        const short = moved != units;
        if (short) {
            channel.faults +%= 1;
            channel.relatch(saved);
        }
        channel.dmcra = xfer.withCount(channel.dmcra, channel.pending);
        channel.dmcrb = channel.blocks;
        return short;
    }

    /// Move `units` units, walking each address by what its mode says. A unit
    /// memory refuses stops the transfer where it stands rather than skipping
    /// on, so the addresses left behind are the ones that faulted.
    fn copy(self: *Dmac, channel: *Channel, shape: xfer.Plan, units: u32) u32 {
        const memory = self.memory.?;
        const width = shape.unit();
        const source_step = shape.step(shape.source);
        const dest_step = shape.step(shape.destination);
        var cell: [4]u8 = undefined;
        var moved: u32 = 0;
        while (moved < units) : (moved += 1) {
            const slice = cell[0..width];
            memory.read(channel.dmsar, slice) catch return moved;
            memory.write(channel.dmdar, slice) catch return moved;
            channel.dmsar = xfer.walk(channel.dmsar, source_step);
            channel.dmdar = xfer.walk(channel.dmdar, dest_step);
        }
        return moved;
    }

    /// The transfer is synchronous here, so ACT is down again by the time the
    /// store returns. A spent count takes DTE down with it (dev leaves it up,
    /// and its zero count then reads as a full 1024 units on the next
    /// request) and queues the transfer-end interrupt if DMINT.DTIE is set.
    fn settle(self: *Dmac, index: usize, shape: xfer.Plan) void {
        const channel = &self.channels[index];
        channel.dmsts &= ~field.act;
        if (!channel.done(shape)) return;
        channel.dmcnt &= ~field.dte;
        channel.dmsts |= field.dtif;
        channel.completions +%= 1;
        if (channel.dmint & field.dtie == 0) return;
        self.due.append(event_base + @as(u16, @intCast(index))) catch {};
    }

    fn refuse(self: *Dmac, reason: Refusal) void {
        self.last_refusal = reason;
        self.refused +%= 1;
    }

    pub fn read(self: *Dmac, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        const index = offset / channel_stride;
        if (index >= channel_count) return 0;
        const local = offset % channel_stride;
        const value = regs.wordValue(&self.channels[index], lanes.word(local));
        return lanes.part(value, lanes.lane(local), width);
    }

    pub fn write(self: *Dmac, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        const index = offset / channel_stride;
        if (index >= channel_count) return;
        const local = offset % channel_stride;
        const base = lanes.word(local);
        const at = lanes.lane(local);
        const channel = &self.channels[index];
        const merged = lanes.merge(regs.wordValue(channel, base), at, width, value);
        const asked = regs.apply(channel, base, merged, lanes.named(at, width));
        if (asked) |ask| self.request(index, ask.continuous);
    }

    pub fn block(self: *Dmac) periph.Block {
        return .{
            .name = "DMAC channels",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Dmac = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Dmac = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}

/// The base address of one channel's registers.
pub fn channelAddress(index: usize) u32 {
    return win_base + channel_stride * @as(u32, @intCast(index));
}
