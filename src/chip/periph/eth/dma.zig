//! The CPU agent's descriptor engine: the rings in guest RAM, the frames that
//! leave through them, and the frames that arrive into them.
//!
//! The firmware points the gateway at a LINKFIX table, hangs a chain of
//! descriptors off each entry, and kicks a queue through GWTRC. This walks
//! that, moves the bytes, and writes the descriptor back so the driver's
//! completion poll resolves.
//!
//! Ported from the TX/RX halves of board_periph_eth.c on dev, with five
//! things that model does not do.
//!
//! A FRAME ONLY MOVES ON A RUNNING GATEWAY. dev checks the mode before its
//! per-tick RX pump and not before a TX kick, so an image that kicks a queue
//! on a gateway still in CONFIG has its frame delivered in the emulator and
//! nothing on the bench. Refused and counted here.
//!
//! A BUFFER HAS TO BE SOMEWHERE THE GATEWAY CAN REACH. dev follows the
//! descriptor's pointer wherever it points, reads the frame out of it and
//! writes a received frame into it, so a half-built ring has the emulator
//! marshalling the peripheral window into a frame and writing frame bytes
//! over whatever the pointer happened to hold. Descriptor and buffer must lie
//! in RAM a bus initiator reaches here, which is the on-chip SRAM and the
//! external SDRAM through either alias; memmap.initiator_ram says why DTCM is
//! not one of them.
//!
//! A RING THAT LINKS BACK ON ITSELF IS NOT WALKED SIXTY-FOUR TIMES. dev
//! refuses only a link straight back to the same descriptor, so a cycle two
//! links long is walked to the bound on every single tick. Any address seen
//! twice ends the walk here, counted.
//!
//! A FRAME TOO BIG FOR THE SLOT IS NOT CUT INTO IT. dev asks the far end for
//! as many bytes as the slot holds and stages whatever comes back, so a frame
//! longer than the slot is delivered truncated and counted as received. Here
//! it stays queued and is counted, which is what a MAC with no room does.
//!
//! A DESCRIPTOR IS COMPLETED WHEN THE FRAME LEFT. dev's sink swallows
//! everything, so the descriptor comes back FEMPTY whatever happened. Here a
//! far end with no room leaves the descriptor owned by the gateway, and the
//! driver's own retry sees it.
const std = @import("std");

const Guest = @import("../../core/cpu/memory/guest/guest.zig").Guest;
const memmap = @import("../../core/memmap.zig");
const desc = @import("desc.zig");
const eth_line = @import("line.zig");

/// What the engine would not do, and why. Every one of these is a case dev
/// carries out silently or not at all.
pub const Refusals = struct {
    stopped: u32 = 0,
    fragment: u32 = 0,
    runt: u32 = 0,
    oversize: u32 = 0,
    off_ram: u32 = 0,
    blocked: u32 = 0,
    looped: u32 = 0,
    ring_full: u32 = 0,
    too_big: u32 = 0,

    pub fn any(self: Refusals) bool {
        return self.stopped + self.fragment + self.runt + self.oversize + self.off_ram +
            self.blocked + self.looped + self.ring_full + self.too_big != 0;
    }
};

pub const Dma = struct {
    /// The machine the rings live in. A board built by a test without one
    /// moves nothing, which is the only way this is ever null.
    memory: ?Guest = null,
    /// The wire to the far end, a board part the board wires in. Null for a
    /// test with nothing on the other end: a frame out then has nowhere to
    /// go and nothing comes in.
    link: ?eth_line.Wire = null,
    /// GWDCBAC: where the LINKFIX table is.
    linkfix: u32 = 0,
    /// Queues GWDCC marked for reception, one bit each. dev keeps only the
    /// last queue named, so a driver with a queue per priority had frames
    /// staged into one of them and polled the rest forever.
    receiving: u64 = 0,
    tx_frames: u32 = 0,
    rx_frames: u32 = 0,
    kicks: u32 = 0,
    refused: Refusals = .{},
    /// Where a frame is marshalled between the ring and the far end.
    stage: [desc.limits.frame_max]u8 = undefined,

    /// A TX request word: one bit per queue, bit zero being queue `first`.
    pub fn kick(self: *Dma, bits: u32, first: u32, operational: bool) void {
        var bit: u32 = 0;
        while (bit < 32) : (bit += 1) {
            const mask = @as(u32, 1) << @as(u5, @intCast(bit));
            if (bits & mask != 0) self.kickQueue(first + bit, operational);
        }
    }

    /// One chunk boundary: stage what the far end has into every reception
    /// queue the firmware configured.
    pub fn tick(self: *Dma, operational: bool) void {
        if (!operational or self.linkfix == 0) return;
        var queue: u32 = 0;
        while (queue < 64) : (queue += 1) {
            const mask = @as(u64, 1) << @as(u6, @intCast(queue));
            if (self.receiving & mask == 0) continue;
            const chain = self.chainOf(queue) orelse continue;
            self.drain(chain);
        }
    }

    pub fn quiet(self: *const Dma) bool {
        return self.kicks == 0 and self.tx_frames == 0 and self.rx_frames == 0 and
            !self.refused.any();
    }

    fn kickQueue(self: *Dma, queue: u32, operational: bool) void {
        self.kicks += 1;
        if (!operational) {
            self.refused.stopped += 1;
            return;
        }
        const chain = self.chainOf(queue) orelse return;
        const head = self.read(chain) orelse return;
        if (head.dt != .fsingle) {
            // A multi-fragment chain is not modelled. Leaving the descriptor
            // alone is what lets the driver's own timeout fire, rather than
            // a completion it never earned.
            self.refused.fragment += 1;
            return;
        }
        const frame = self.frameOf(head) orelse return;
        const wire = self.link orelse {
            self.refused.blocked += 1;
            return;
        };
        if (!wire.send(frame)) {
            self.refused.blocked += 1;
            return;
        }
        self.setDt(chain, .fempty);
        self.tx_frames += 1;
    }

    /// The bytes a TX descriptor points at, or nothing when it does not
    /// describe a frame this model will move.
    fn frameOf(self: *Dma, head: desc.Desc) ?[]const u8 {
        if (head.ds < desc.limits.frame_min) {
            self.refused.runt += 1;
            return null;
        }
        if (head.ds > desc.limits.frame_max) {
            self.refused.oversize += 1;
            return null;
        }
        if (!memmap.initiatorHolds(head.ptr, head.ds)) {
            self.refused.off_ram += 1;
            return null;
        }
        const memory = self.memory orelse return null;
        memory.read(head.ptr, self.stage[0..head.ds]) catch return null;
        return self.stage[0..head.ds];
    }

    fn drain(self: *Dma, chain: u32) void {
        var staged: u32 = 0;
        while (staged < desc.limits.inject) : (staged += 1) {
            // Ask before claiming a slot, so a frame is never dequeued and
            // then dropped for want of somewhere to put it.
            const wire = self.link orelse return;
            const len = wire.waiting() orelse return;
            const slot = self.freeSlot(chain) orelse return;
            if (!self.stageInto(slot, len)) return;
            wire.drop();
            self.setDs(slot, len);
            self.setDt(slot, .fsingle);
            self.rx_frames += 1;
        }
    }

    /// Write the waiting frame into the slot's buffer, if it fits in it and
    /// the buffer is somewhere a frame may be written.
    fn stageInto(self: *Dma, slot: u32, len: u32) bool {
        const at = self.read(slot) orelse return false;
        if (at.ds == 0) return false;
        if (!memmap.initiatorHolds(at.ptr, at.ds)) {
            self.refused.off_ram += 1;
            return false;
        }
        if (len > at.ds) {
            self.refused.too_big += 1;
            return false;
        }
        const wire = self.link orelse return false;
        const frame = wire.peek() orelse return false;
        const memory = self.memory orelse return false;
        memory.write(at.ptr, frame) catch return false;
        return true;
    }

    /// The first reception slot on the ring at `chain`.
    fn freeSlot(self: *Dma, chain: u32) ?u32 {
        var seen: [desc.limits.walk]u32 = undefined;
        var count: usize = 0;
        var at = chain;
        while (count < desc.limits.walk) : (count += 1) {
            for (seen[0..count]) |was| {
                if (was != at) continue;
                self.refused.looped += 1;
                return null;
            }
            seen[count] = at;
            const entry = self.read(at) orelse return null;
            if (desc.free(entry.dt)) return at;
            at = if (desc.chains(entry.dt)) entry.ptr else at +% desc.size;
            if (at == 0) return null;
        }
        self.refused.ring_full += 1;
        return null;
    }

    /// The head of queue `queue`'s chain, out of the LINKFIX table.
    fn chainOf(self: *Dma, queue: u32) ?u32 {
        if (self.linkfix == 0) return null;
        const entry = self.read(self.linkfix +% (queue *% desc.size)) orelse return null;
        if (entry.ptr == 0) return null;
        return entry.ptr;
    }

    fn read(self: *Dma, at: u32) ?desc.Desc {
        if (!memmap.initiatorHolds(at, desc.size)) {
            self.refused.off_ram += 1;
            return null;
        }
        const memory = self.memory orelse return null;
        var raw: [desc.size]u8 = undefined;
        memory.read(at, &raw) catch return null;
        return desc.Desc.decode(raw);
    }

    fn setDt(self: *Dma, at: u32, dt: desc.Dt) void {
        const memory = self.memory orelse return;
        var old: [1]u8 = undefined;
        memory.read(at + desc.layout.dt, &old) catch return;
        memory.write(at + desc.layout.dt, &[_]u8{desc.dtByte(old[0], dt)}) catch return;
    }

    fn setDs(self: *Dma, at: u32, ds: u32) void {
        const memory = self.memory orelse return;
        var old: [1]u8 = undefined;
        memory.read(at + desc.layout.ds_high, &old) catch return;
        memory.write(at + desc.layout.ds_low, &desc.dsBytes(old[0], ds)) catch return;
    }
};
