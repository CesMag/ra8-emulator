//! IPC: the cross-core mailbox, and which core a poke is meant to wake.
//!
//! The IPC unit sits at 0x4002_0000 and carries four channel windows from
//! 0xC0 up, 0x20 apart: IPC0 channels 0 and 1 run CPU1 -> CPU0, IPC1
//! channels 2 and 3 run CPU0 -> CPU1. A channel is a pending-IRQ byte plus a
//! four-stage message FIFO. The sender pushes a word into TXD and pokes
//! ISET; the receiver takes the interrupt, reads STA to see which line was
//! set, drains RXD while STA.RDY is up, and acknowledges through CLR. That
//! handshake is what the dual-core examples replace their done-flag polls
//! with, so it is what a headless run can check.
//!
//! Ported from board_periph_ipc.c on dev, with three things that model does
//! not do.
//!
//! A POKE WAKES THE RECEIVER, NOT THE SENDER. dev raises the event on
//! whichever engine performed the ISET store, for every channel, so a CPU0
//! write to an IPC1 channel raises ELC_EVENT_IPC_IRQ1 on CPU0 itself: the
//! core that sent the message takes the interrupt announcing it. Here the
//! receiving side decides. IPC0 channels raise into this board's event path,
//! because their receiver is the core this build runs; an IPC1 poke is
//! counted as addressed to a core that is not here and raises nothing, which
//! is what the run should say rather than a wake that went the wrong way.
//!
//! THE SEMAPHORES TAKE THE LOCK. dev answers zero to every read below the
//! first channel window and drops every write there, so a driver that
//! claims a semaphore and reads it back to see whether it won reads zero
//! forever and can spin without end. Here IPCSEMn and the two NMI
//! doorbells are a model of their own in sync.zig: a read of a
//! semaphore takes the lock as a side effect and hands back the value from
//! before it, the way HUM Ch 3.2.3 p 210 specifies, so the second claimant
//! is told it lost. What is left of the region below 0xC0 is still shadow.
//!
//! A DROPPED MESSAGE IS COUNTED. dev latches FERR on a write into a full
//! FIFO and RERR on a read of an empty one, and its end-of-run line prints
//! only pushes and pops, so a run that overran the four stages reads exactly
//! like one that did not. The latches are kept, and the words the FIFO could
//! not take and the reads that found nothing are counted and reported.
//!
//! THE MESSAGE PORTS ARE WORD PORTS. TXD and RXD carry one 32-bit message,
//! not a bag of independently addressable bits the way STA, ISET and CLR do,
//! and the FIFO stage behind them moves whole. So a store narrower than a
//! word would push a message three quarters of which the firmware never
//! wrote, and a load narrower than a word would consume a stage and hand
//! back one lane of it with the rest gone for good. Both are refused and
//! counted here rather than taken: the FIFO keeps what it has, and the run
//! says the access was the wrong width. dev takes either one, so on that
//! tree a driver reading a message through two halfword loads drains two
//! stages and assembles a word out of the low halves of both.
//!
//! THE SEMAPHORES BELOW THE CHANNELS take the same question and answer it
//! differently, because LOCK is one bit rather than a message: an access
//! that names bit 0 carries the lock whatever its width, and one that does
//! not carries nothing and must not take it. sync.zig owns that rule;
//! this file's job is to hand it the lanes the access actually named
//! instead of only the offset it landed on.
//!
//! NOT MODELLED, AND NOT GUESSED: any IPC interrupt besides the two receive
//! events, and NMI delivery, which is latched and counted here but reaches
//! no core. The event is queued for the chunk boundary rather than raised
//! inside the store, which is how every other block on this board offers
//! one.
const std = @import("std");
const Bounded = @import("../../core/bounded.zig").Bounded;
const periph = @import("../registry.zig");
const lanes = @import("../lanes.zig");
const prcr = @import("../prcr.zig");
pub const sync = @import("sync.zig");
pub const attr = @import("attr.zig");
const repeating = @import("repeat.zig");

/// IPC geometry (ra8_ipc_regs.h). The bus folds the Non-secure alias onto
/// this base before it arrives.
pub const win_base: u32 = 0x4002_0000;
pub const win_span: u32 = 0x140;

/// The channel windows: four of them, 0x20 apart, starting at 0xC0. Below
/// 0xC0 are the semaphores and the NMI windows, which sync.zig owns.
pub const ch0_offset: u32 = 0xC0;
pub const ch_stride: u32 = 0x20;
pub const ch_count: usize = 4;
/// Channels below this are IPC0 (CPU1 -> CPU0); the rest are IPC1.
pub const unit_split: usize = 2;
/// Four stages, the depth the hardware manual fixes.
pub const fifo_depth: usize = 4;

/// The registers this model interprets. Everything else is shadow.
pub const off_sta: u32 = 0x00;
pub const off_iset: u32 = 0x04;
pub const off_txd: u32 = 0x08;
pub const off_rxd: u32 = 0x0C;
pub const off_clr: u32 = 0x10;

pub const field = struct {
    /// STA and CLR: the eight maskable IRQ lines.
    pub const irq: u32 = 0x0000_00FF;
    /// STA.RDY, the receive FIFO holding something.
    pub const rdy: u32 = 0x0001_0000;
    /// STA.FULL, all four stages taken.
    pub const full: u32 = 0x0002_0000;
    /// STA.RERR, a read that found the FIFO empty.
    pub const rerr: u32 = 0x0100_0000;
    /// STA.FERR, a write that found the FIFO full.
    pub const ferr: u32 = 0x0200_0000;
    /// CLR.RST, empty the FIFO.
    pub const rst: u32 = 0x0001_0000;
    /// CLR.RCLR and CLR.FCLR, drop the sticky error latches.
    pub const rclr: u32 = 0x0100_0000;
    pub const fclr: u32 = 0x0200_0000;
};

/// The receive events the two units raise on their own side.
pub const event = struct {
    pub const ipc0_irq: u16 = 0x05B;
    pub const ipc1_irq: u16 = 0x05C;
};

/// One event per boundary: the line is already pending in the controller, so
/// a second raise before the core takes it would be the same line twice.
pub const Due = Bounded(u16, 1);

const shadow_words: usize = win_span / 4;

/// One channel: the pending IRQ lines, the four-stage message FIFO behind
/// them, and what the run should be told about the traffic it carried.
pub const Channel = struct {
    /// The IRQ lines ISET has latched and CLR has not yet dropped.
    pending: u32 = 0,
    /// Ring storage: `rd` is the oldest entry, `count` the fill level.
    word: [fifo_depth]u32 = @splat(0),
    rd: usize = 0,
    count: usize = 0,
    /// The sticky error latches, which only CLR drops.
    rerr: bool = false,
    ferr: bool = false,
    /// ISET stores that latched at least one line.
    sends: u32 = 0,
    /// Words the FIFO took, and words it gave back.
    pushes: u32 = 0,
    pops: u32 = 0,
    /// Words a full FIFO could not take: the message never arrived.
    lost: u32 = 0,
    /// Reads that found the FIFO empty: no message was there to take.
    starved: u32 = 0,
    /// Loads of RXD narrower than a word. Refused, so the stage stays.
    narrow_reads: u32 = 0,
    /// Stores to TXD narrower than a word. Refused, so no part-written
    /// message is pushed.
    narrow_writes: u32 = 0,

    pub fn quiet(self: *const Channel) bool {
        return self.pending == 0 and self.count == 0 and self.sends == 0 and
            self.pushes == 0 and self.pops == 0 and self.lost == 0 and
            self.starved == 0 and self.narrow_reads == 0 and
            self.narrow_writes == 0 and !self.rerr and !self.ferr;
    }

    /// STA is composed, never stored: the FIFO bits follow the ring and the
    /// error bits follow the latches.
    pub fn status(self: *const Channel) u32 {
        var value: u32 = self.pending;
        if (self.count > 0) value |= field.rdy;
        if (self.count >= fifo_depth) value |= field.full;
        if (self.rerr) value |= field.rerr;
        if (self.ferr) value |= field.ferr;
        return value;
    }

    /// Latch the written IRQ lines. Returns whether anything was named, so
    /// the unit knows a store worth an event from one that said nothing.
    fn set(self: *Channel, value: u32) bool {
        const bits = value & field.irq;
        if (bits == 0) return false;
        self.pending |= bits;
        self.sends +%= 1;
        return true;
    }

    /// Push one word. A full FIFO drops it and latches FERR: on silicon the
    /// message is gone, and the run should say how many went that way.
    fn push(self: *Channel, value: u32) void {
        if (self.count >= fifo_depth) {
            self.ferr = true;
            self.lost +%= 1;
            return;
        }
        self.word[(self.rd + self.count) % fifo_depth] = value;
        self.count += 1;
        self.pushes +%= 1;
    }

    /// Pop the oldest word. An empty FIFO latches RERR and hands back zero:
    /// there was no message, and serving the last one again would invent it.
    fn pop(self: *Channel) u32 {
        if (self.count == 0) {
            self.rerr = true;
            self.starved +%= 1;
            return 0;
        }
        const taken = self.word[self.rd];
        self.rd = (self.rd + 1) % fifo_depth;
        self.count -= 1;
        self.pops +%= 1;
        return taken;
    }

    /// CLR is write-one-to-clear over the IRQ lines, plus the FIFO reset and
    /// the two error-latch clears.
    fn clear(self: *Channel, value: u32) void {
        self.pending &= ~(value & field.irq);
        if (value & field.rst != 0) {
            self.rd = 0;
            self.count = 0;
        }
        if (value & field.rclr != 0) self.rerr = false;
        if (value & field.fclr != 0) self.ferr = false;
    }
};

/// The semaphore and NMI half of the block, re-exported so a caller
/// reaches it the way it reaches the channels.
pub const synchro = sync;
pub const attribution = attr;

/// Where an offset in the window lands.
const Slot = struct { index: usize, reg: u32 };

pub const Ipc = struct {
    channels: [ch_count]Channel = @splat(Channel{}),
    /// IPCSEM0..15 and the two NMI doorbells, below the channel windows.
    locks: sync.Sync = .{},
    /// What neither the channels nor the locks own: the gap at 0x040 and
    /// the padding inside each window. Held so a read-modify-write
    /// survives, never interpreted.
    shadow: [shadow_words]u32 = @splat(0),
    /// An IPC0 poke waiting for the chunk boundary to be offered as an event.
    raised: bool = false,
    /// Events handed to the board's event path.
    wakes: u32 = 0,
    /// ISET stores on a channel whose receiving core this build does not run.
    undelivered: u32 = 0,
    /// IPCSAR / IPCPAR, which say whether a channel was given to the
    /// Non-Secure world. They live in CPSCU rather than this window, so
    /// they are a block of their own; they are held here because they
    /// attribute these channels and nothing else.
    attrib: attr.Attribution = .{},

    pub fn init() Ipc {
        return .{};
    }

    /// Hand the attribution pair the protection model, without which it
    /// cannot tell whether PRC4 was open and so accepts nothing.
    pub fn protect(self: *Ipc, protection: *const prcr.Prcr) void {
        self.attrib = attr.Attribution.init(protection);
    }

    /// The CPSCU window that attributes these channels, offered separately
    /// because it is nowhere near this block's base.
    pub fn attributionBlock(self: *Ipc) periph.Block {
        return self.attrib.block();
    }

    pub fn quiet(self: *const Ipc) bool {
        if (self.wakes != 0 or self.undelivered != 0) return false;
        if (!self.attrib.quiet()) return false;
        if (!self.locks.quiet()) return false;
        for (&self.channels) |*unit| {
            if (!unit.quiet()) return false;
        }
        return true;
    }

    /// The receive event a poke earned, offered once per boundary.
    pub fn dueEvents(self: *Ipc) Due {
        var due = Due{};
        if (!self.raised) return due;
        self.raised = false;
        self.wakes +%= 1;
        due.appendAssumeCapacity(event.ipc0_irq);
        return due;
    }

    pub fn read(self: *Ipc, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        if (offset >= win_span) return 0;
        const byte = offset % 4;
        if (decode(offset)) |slot| {
            const unit = &self.channels[slot.index];
            switch (slot.reg) {
                off_sta => return lanes.part(unit.status(), byte, width),
                // A stage is consumed by the load, so a load that cannot
                // carry a whole one must not make it. The refusal reads
                // back zero, which is what a stage nobody took holds for
                // the caller anyway.
                off_rxd => {
                    if (width < 4) {
                        unit.narrow_reads +%= 1;
                        return 0;
                    }
                    return unit.pop();
                },
                // ISET, TXD and CLR are actions; nothing sits behind them.
                off_iset, off_txd, off_clr => return 0,
                else => {},
            }
        } else if (self.locks.read(offset, lanes.named(byte, width))) |value| {
            return lanes.part(value, byte, width);
        }
        return lanes.part(self.shadow[offset / 4], byte, width);
    }

    pub fn write(self: *Ipc, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        if (offset >= win_span) return;
        const byte = offset % 4;
        if (decode(offset)) |slot| {
            const named = lanes.merge(0, byte, width, value);
            switch (slot.reg) {
                // ISET and CLR name lines, one bit each, so the lanes a
                // narrow store reaches are exactly the lines it asks for.
                off_iset => self.poke(slot.index, named),
                // A message is a word, not lines: the lanes this store did
                // not name hold nothing to push with it.
                off_txd => {
                    if (width < 4) {
                        self.channels[slot.index].narrow_writes +%= 1;
                        return;
                    }
                    self.channels[slot.index].push(value);
                },
                off_clr => self.channels[slot.index].clear(named),
                // Status, and a status register does not take a store.
                off_sta, off_rxd => {},
                else => self.shadowWrite(offset, byte, width, value),
            }
            return;
        }
        if (self.locks.write(offset, lanes.merge(0, byte, width, value))) return;
        self.shadowWrite(offset, byte, width, value);
    }

    /// Latch the lines, then decide who the poke was for. Only the unit whose
    /// receiver is the core this build runs raises anything.
    fn poke(self: *Ipc, index: usize, value: u32) void {
        if (!self.channels[index].set(value)) return;
        if (index < unit_split) {
            self.raised = true;
        } else {
            self.undelivered +%= 1;
        }
    }

    fn shadowWrite(self: *Ipc, offset: u32, byte: u32, width: u3, value: u32) void {
        const word = offset / 4;
        self.shadow[word] = lanes.merge(self.shadow[word], byte, width, value);
    }

    pub fn block(self: *Ipc) periph.Block {
        return .{
            .name = "IPC",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
            .repeatFn = repeatThunk,
        };
    }
};

/// Which channel an offset belongs to, and which register inside it. Null
/// for the semaphore and NMI region below the first window.
fn decode(offset: u32) ?Slot {
    if (offset < ch0_offset) return null;
    const relative = offset - ch0_offset;
    const index = relative / ch_stride;
    if (index >= ch_count) return null;
    return .{ .index = index, .reg = (relative % ch_stride) & ~@as(u32, 3) };
}

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Ipc = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn repeatThunk(context: *anyopaque, address: u32, width: u3, times: u64) bool {
    const self: *Ipc = @ptrCast(@alignCast(context));
    return repeating.repeat(self, address -% win_base, width, times);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Ipc = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}

/// The base address of one channel window, so a test or a later slice does
/// not do the arithmetic itself.
pub fn channelAddress(index: usize) u32 {
    return win_base + ch0_offset + @as(u32, @intCast(index)) * ch_stride;
}
