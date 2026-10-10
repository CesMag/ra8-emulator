//! CAN-FD: the two controllers, the mode state machine a driver waits on,
//! and the difference between a frame that was transmitted and one that was
//! received.
//!
//! CANFD0 sits at 0x4038_0000 and CANFD1 at 0x4038_2000, each a 0x1920-byte
//! channel window (ra8_canfd_regs.h, FSP R_CANFD_Type). There is no bus and
//! no other node here, so what a headless run can observe is the internal
//! loopback the `canfd_loopback` and `canfd_filter` examples drive: out of
//! reset mode, program the filter, write a frame into TX message buffer 0,
//! assert CFDTMC[0].TMTR, then poll RX FIFO 0 and read the frame back.
//!
//! Ported from board_periph_canfd.c on dev, with five things that model does
//! not do.
//!
//! THE PART COMES UP IN RESET MODE. dev powers every register up at zero, and
//! zero in CFDGSTS reads as operation mode, so an image that never programmed
//! the state machine transmits there and would sit in global reset on
//! silicon. Here both machines power up in reset, which is also what the
//! driver's first poll is waiting to see.
//!
//! A TRANSMIT NEEDS AN OPERATING CHANNEL. dev copies the TX buffer into the
//! receive stage on any TMTR whatever the two mode registers say. Here a
//! request made while either machine is out of operation mode moves nothing:
//! it is refused and counted, so the run says the channel was never started.
//!
//! THE RECEIVE SIDE IS A FIFO. dev keeps one stage and overwrites it, so a
//! second frame delivered before the firmware reads silently replaces the
//! first and the reader never learns it missed one. Here the stages queue,
//! oldest first, and a delivery with no stage free is counted as lost.
//!
//! A POP TAKES A FRAME THAT WAS THERE. dev's CFDRFPCTR write sets RFEMP and
//! drops RFIF whatever the FIFO holds, so a pop with nothing queued reports
//! an empty FIFO the firmware never drained, and the window keeps answering
//! with the frame it last held. Here a pop of an empty FIFO is refused and
//! counted, and the window reads zero once the last frame has been taken.
//!
//! STATUS IS WHAT THE CONTROLLER RAISED. dev drops every store into the flat
//! register array, so firmware can write CFDRFSTS itself and read back a
//! frame that never arrived. Refused and counted here, the SRAMESR / CETCR /
//! INTS pattern, and narrow writes keep the bytes they do not name, which
//! dev's reg[off / 4] = value wipes.
//!
//! AN ERROR FLAG IS THE CONTROLLER'S TO RAISE. CFDCnERFL was not interpreted
//! at all, so it fell into the flat shadow and read back whatever was last
//! written at it. The flags are write-ZERO-to-clear, so a driver that acks
//! them the way most CAN parts want, by writing ones, SET all fifteen here,
//! and the driver's own clear writes the inverse of its mask so the rest
//! survived their own acknowledgement. The dispatch then hands that word to
//! the application as errors that never happened. The rule and its evidence
//! live in src/chip/periph/canfd/error_flags.zig.
//!
//! A MODE WRITE LANDS ON NOTHING WHILE THE MACHINE IS ASLEEP. Neither model
//! knew the sleep request beside the mode field, so a driver that leaves it
//! set reached operation mode here and hangs on silicon. The rule and its
//! evidence live in src/chip/periph/canfd/sleep.zig.
//!
//! KEPT FROM DEV DELIBERATELY: the acceptance filter and its open-when-empty
//! rule, so an image that programs no CFDGAFL entry keeps receiving
//! everything, and a programmed entry drops the identifier it does not match.
//!
//! NOT MODELLED, AND NOT GUESSED: bit timing and the rate registers, the
//! other RX FIFOs and the receive buffers, TX queues and history, error
//! counters and the bus-off machine, and every interrupt besides the
//! RX-FIFO one. The rest of the window is shadowed, and never read.
const periph = @import("../registry.zig");
const lanes = @import("../lanes.zig");
pub const fifo = @import("fifo.zig");
pub const sleep = @import("sleep.zig");
pub const rx_config = @import("rx_config.zig");
pub const rx_status = @import("rx_status.zig");
pub const tx_status = @import("tx_status.zig");
pub const regs = @import("regs.zig");
const errors = @import("error_flags.zig");

/// The geometry, the offsets and the field masks, split into
/// regs.zig and reached through the block the way the other parts of
/// it are.
pub const unit0_base = regs.unit0_base;
pub const unit1_base = regs.unit1_base;
pub const win_span = regs.win_span;
pub const unit_count = regs.unit_count;
pub const off_cnctr = regs.off_cnctr;
pub const off_cnsts = regs.off_cnsts;
pub const off_gctr = regs.off_gctr;
pub const off_gsts = regs.off_gsts;
pub const off_rfsts0 = regs.off_rfsts0;
pub const off_rfpctr0 = regs.off_rfpctr0;
pub const off_tmc0 = regs.off_tmc0;
pub const off_tmsts0 = regs.off_tmsts0;
pub const off_afl = regs.off_afl;
pub const off_rf0 = regs.off_rf0;
pub const off_tm0 = regs.off_tm0;
pub const afl = regs.afl;
pub const field = regs.field;
pub const event = regs.event;
pub const Due = regs.Due;
pub const Mode = regs.Mode;

/// The error-flag rule, reached as `canfd.error_flags` the way the other
/// split parts of this block are reached through it.
pub const error_flags = errors;

/// The CFDRFSTS rule, reached the same way.
pub const rx_flags = rx_status;

const part = lanes.part;
const merge = lanes.merge;

const shadow_words: usize = win_span / 4;
const frame_span: u32 = @as(u32, fifo.frame_words) * 4;

/// One controller: the two mode machines, the receive FIFO, and what the run
/// should be told about the traffic it was given.
pub const Unit = struct {
    /// The state machines, both in reset from power-up as on silicon.
    global: Mode = .reset,
    channel: Mode = .reset,
    /// Both sleep requests, set from power-up. See sleep.zig.
    dozing: sleep.Pair = .{},
    /// CFDTMC[0], with TMTR cleared once the frame has gone.
    tmc: u32 = 0,
    /// CFDTMSTS[0], the transmit result. Set by the controller, cleared by
    /// software, and the gate on every later request. See
    /// src/chip/periph/canfd/tx_status.zig.
    tx: tx_status.Status = .{},
    /// CFDCnERFL: the error flags, which only the controller can raise.
    faults: errors.Errors = .{},
    queue: fifo.Fifo = .{},
    shadow: [shadow_words]u32 = @splat(0),
    /// Frames clocked out of the transmit buffer.
    sent: u32 = 0,
    /// Frames the filter accepted and a stage took.
    received: u32 = 0,
    /// Frames transmitted and dropped by the acceptance filter.
    filtered: u32 = 0,
    /// Transmit requests made out of operation mode: nothing left.
    refused: u32 = 0,
    /// Accepted frames with no stage free.
    lost: u32 = 0,
    /// CFDRFSTS[0]'s latched half: RFMLT, and the stores aimed at it. See
    /// src/chip/periph/canfd/rx_status.zig.
    rx_sts: rx_status.Status = .{},
    /// Accepted frames dropped because CFDRFCC.RFE was never set, so there
    /// was no FIFO to queue them in. See src/chip/periph/canfd/rx_config.zig.
    unarmed: u32 = 0,
    /// CFDRFCC[0], the RX FIFO's own configuration.
    rx: rx_config.Config = .{},
    /// Pops of an empty FIFO.
    starved: u32 = 0,
    /// Stores into a status register the controller owns.
    faked: u32 = 0,

    pub fn quiet(self: *const Unit) bool {
        return self.sent == 0 and self.refused == 0 and self.starved == 0 and
            self.faked == 0 and self.unarmed == 0 and self.faults.quiet() and
            self.rx.quiet() and self.tx.quiet() and self.dozing.quiet() and
            self.rx_sts.quiet() and
            self.global == .reset and self.channel == .reset;
    }

    /// Both machines have to be in operation before a frame can go.
    pub fn running(self: *const Unit) bool {
        return self.global == .operation and self.channel == .operation;
    }

    fn globalStatus(self: *const Unit) u32 {
        return switch (self.global) {
            .reset => field.grststs,
            .halt => field.ghltsts,
            .operation => 0,
        };
    }

    fn channelStatus(self: *const Unit) u32 {
        return switch (self.channel) {
            .reset => field.crststs,
            .halt => field.chltsts,
            .operation => 0,
        };
    }

    /// CFDRFSTS: the queue's live state plus whatever RFMLT is still holding.
    fn fifoStatus(self: *const Unit) u32 {
        return self.rx_sts.read(self.queue.empty(), self.queue.full());
    }

    /// Does the programmed filter let this identifier through? An entry is
    /// active once its mask is non-zero, and with no active entry the filter
    /// is open. Carried from dev, including the open-when-empty rule.
    pub fn accepts(self: *const Unit, id: u32) bool {
        var active = false;
        for (0..afl.count) |slot| {
            const entry = off_afl + @as(u32, @intCast(slot)) * afl.stride;
            const mask = self.shadow[entry / 4 + 1] & fifo.id_mask.extended;
            if (mask == 0) continue;
            active = true;
            const wanted = self.shadow[entry / 4] & fifo.id_mask.extended;
            if (id & mask == wanted & mask) return true;
        }
        return !active;
    }

    /// Clock the frame in TX message buffer 0 out and, if the filter takes
    /// it, into the receive FIFO. True when a stage took it, which is the
    /// only case worth an event.
    fn transmit(self: *Unit) bool {
        if (!self.running()) {
            self.refused +%= 1;
            return false;
        }
        // TMTR is only honoured while TMTRF reads 00b. A result the
        // firmware never cleared turns every later request away.
        if (!self.tx.accepts()) return false;
        var frame = fifo.Frame{};
        for (&frame.words, 0..) |*word, index| {
            word.* = self.shadow[off_tm0 / 4 + index];
        }
        // The frame left the buffer whatever the filter decides: the request
        // completes and TMTR drops, as it does when the arbitration is won.
        self.sent +%= 1;
        self.tmc &= ~field.tmtr;
        self.tx.complete();
        if (!self.accepts(frame.id())) {
            self.filtered +%= 1;
            return false;
        }
        // A FIFO the firmware never enabled is not a full FIFO: the frame
        // has nowhere to go at all, so it is dropped rather than lost.
        if (!self.rx.enabled()) {
            self.unarmed +%= 1;
            return false;
        }
        if (!self.queue.push(frame)) {
            self.lost +%= 1;
            // The firmware's only way to find out, and it stands until the
            // firmware lowers it.
            self.rx_sts.lose();
            return false;
        }
        self.received +%= 1;
        return true;
    }

    /// CFDRFPCTR: advance past the frame the window is showing. A pop with
    /// nothing queued is a drain the firmware did not make.
    fn popFrame(self: *Unit) void {
        if (!self.queue.pop()) self.starved +%= 1;
    }

    fn readWord(self: *const Unit, offset: u32) u32 {
        if (offset >= off_rf0 and offset < off_rf0 + frame_span) {
            return self.queue.word((offset - off_rf0) / 4);
        }
        return switch (offset) {
            off_gsts => self.globalStatus() | self.dozing.global.statusBit(),
            off_cnsts => self.channelStatus() | self.dozing.channel.statusBit(),
            off_rfsts0 => self.fifoStatus(),
            rx_config.off_rfcc0 => self.rx.word,
            off_tmc0 => self.tmc,
            off_tmsts0 => self.tx.word,
            errors.off => self.faults.read(),
            // Write-only: the pointer control has nothing behind it.
            off_rfpctr0 => 0,
            else => self.shadow[offset / 4],
        };
    }

    /// Returns true when the frame reached a stage, so the caller can offer
    /// the receive event.
    fn writeWord(self: *Unit, offset: u32, byte: u32, width: u3, value: u32) bool {
        switch (offset) {
            off_gctr => {
                const held = merge(self.shadow[offset / 4], byte, width, value);
                self.shadow[offset / 4] = held;
                if (self.dozing.global.store(held)) self.global = Mode.fromBits(held);
            },
            off_cnctr => {
                const held = merge(self.shadow[offset / 4], byte, width, value);
                self.shadow[offset / 4] = held;
                if (self.dozing.channel.store(held)) self.channel = Mode.fromBits(held);
            },
            off_gsts, off_cnsts => self.faked +%= 1,
            off_rfsts0 => self.rx_sts.store(byte, width, value),
            off_tmsts0 => {
                // Only mailbox 0 is modelled; a store that names none of
                // its byte is a store into a register nothing here owns.
                if (byte == 0) {
                    self.tx.store(merge(self.tx.word, byte, width, value));
                } else {
                    self.faked +%= 1;
                }
            },
            off_tmc0 => {
                self.tmc = merge(self.tmc, byte, width, value);
                if (self.tmc & field.tmtr != 0) return self.transmit();
            },
            errors.off => self.faults.store(byte, width, value),
            off_rfpctr0 => self.popFrame(),
            rx_config.off_rfcc0 => self.rx.store(
                merge(self.rx.word, byte, width, value),
                self.global == .reset,
            ),
            else => {
                const word = offset / 4;
                self.shadow[word] = merge(self.shadow[word], byte, width, value);
            },
        }
        return false;
    }
};

pub const Canfd = struct {
    units: [unit_count]Unit = @splat(Unit{}),
    /// A delivery on CANFD0 waiting for the chunk boundary.
    raised: bool = false,
    /// Events handed to the board's event path.
    wakes: u32 = 0,

    pub fn init() Canfd {
        return .{};
    }

    pub fn quiet(self: *const Canfd) bool {
        if (self.wakes != 0) return false;
        for (&self.units) |*unit| {
            if (!unit.quiet()) return false;
        }
        return true;
    }

    /// The receive event a delivered frame earned, offered once per boundary.
    pub fn dueEvents(self: *Canfd) Due {
        var due = Due{};
        if (!self.raised) return due;
        self.raised = false;
        self.wakes +%= 1;
        due.appendAssumeCapacity(event.can0_rxf);
        return due;
    }

    pub fn read(self: *Canfd, address: u32, width: u3) u32 {
        const index = unitIndex(address) orelse return 0;
        const offset = address - unitBase(index);
        return part(self.units[index].readWord(offset & ~@as(u32, 3)), offset % 4, width);
    }

    pub fn write(self: *Canfd, address: u32, width: u3, value: u32) void {
        const index = unitIndex(address) orelse return;
        const offset = address - unitBase(index);
        const delivered = self.units[index].writeWord(
            offset & ~@as(u32, 3),
            offset % 4,
            width,
            value,
        );
        if (delivered and index == 0) self.raised = true;
    }

    /// One block per controller: the two windows are 0x2000 apart and only
    /// 0x1920 wide, so the gap between them is not ours to answer for.
    pub fn block(self: *Canfd, index: usize) periph.Block {
        return .{
            .name = if (index == 0) "CANFD0" else "CANFD1",
            .base = unitBase(index),
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

/// The base address of one controller, so a test or a later slice does not do
/// the arithmetic itself.
pub fn unitBase(index: usize) u32 {
    return if (index == 0) unit0_base else unit1_base;
}

fn unitIndex(address: u32) ?usize {
    for (0..unit_count) |index| {
        const start = unitBase(index);
        if (address >= start and address - start < win_span) return index;
    }
    return null;
}

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Canfd = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Canfd = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
