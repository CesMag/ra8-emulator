//! SDHI0: the SD host controller, and the card commands it will actually
//! pass on.
//!
//! The block sits at 0x4025_2000 with a 0x200 window (ra8_sdhi_regs.h,
//! ra8_sdhi.c). A native-SD image drives it in two halves. First the SD
//! Physical Layer identification, CMD0 -> CMD8 -> ACMD41 -> CMD2 -> CMD3 ->
//! CMD9 -> CMD7, each one a write to SD_CMD with SD_ARG already loaded, each
//! one polled for SD_INFO1.RSPEND. Then the data phase: CMD17/18 arm a read
//! and CMD24/25 arm a write, and each SD_BUF0 access moves one 32-bit word
//! of a 512-byte block.
//!
//! The card itself, its blocks and the state it is in, is a part outside
//! the MCU behind the line line.zig declares. This file owns the window, the command engine and the
//! FIFO.
//!
//! Ported from board_periph_sdhi.c on dev, with five things that model does
//! not do.
//!
//! A BLOCK COMMAND NEEDS A SELECTED CARD. dev answers R1 "ready" to CMD17
//! from reset and hands over block data, so an image that skips the
//! identification sequence reads real-looking blocks on dev and reads
//! nothing on silicon. The card walks idle -> ready -> ident -> stby ->
//! tran here, and a data command from anywhere but tran is answered with
//! ILLEGAL_COMMAND, arms no data phase, and is counted.
//!
//! THE RESPONSE AND STATUS REGISTERS ARE THE CONTROLLER'S. dev stores
//! anywhere in the window, SD_RSP10..76 and SD_INFO1/2 included, so
//! firmware can write its own card response and read it back as though a
//! card sent it, and can raise RSPEND on itself. A store to SD_RSP10..76 is
//! refused and counted here, the CETCR and SRAMESR pattern. SD_INFO1/2 keep
//! the driver's convention, which dev does not implement either: a flag is
//! acknowledged by writing a zero to it and a one leaves it where it was.
//!
//! SOFT_RST HOLDS THE PART IN RESET. dev clears its engine on both writes
//! of the driver's 0-then-1 sequence and runs commands either way. Bit 0
//! clear is reset asserted here: the FIFO and the flags are cleared and a
//! command issued while it is asserted does nothing and is counted.
//!
//! SD_BUF0 IS A 32-BIT PORT. dev pops or pushes a whole word for an access
//! of any width, so a byte read of the FIFO swallows four bytes of the
//! block and the transfer silently runs short. A narrow access is refused
//! and counted.
//!
//! A FIFO TOUCHED WITH NO DATA PHASE IS COUNTED, and a narrow write only
//! touches the bytes it names: dev returns 0 to a read with nothing armed
//! and swallows the write, so an image whose command failed drains a block
//! of zeros and calls it data, and dev's `regs[off / 4] = value` makes the
//! driver's halfword store to SD_CMD wipe the two bytes above it.
//!
//! NOT MODELLED AND NOT GUESSED: every SDHI interrupt (dev raises none and
//! no header here gives the event numbers), the SD_INFO2 error bits beyond
//! the buffer flags, SD_DMAEN transfers, the clock and timeout fields, and
//! CMD6. They are shadowed so a read-modify-write survives, never read.
const std = @import("std");
const periph = @import("../registry.zig");
pub const line = @import("line.zig");
pub const fifo = @import("fifo.zig");
const bus_lanes = @import("../lanes.zig");
pub const xfer = @import("xfer.zig");
pub const snapshot = @import("snapshot.zig");

pub const win_base: u32 = 0x4025_2000;
pub const win_span: u32 = 0x200;

/// The registers this model interprets. Everything else in the window is
/// shadowed.
pub const off = struct {
    pub const sd_cmd: u32 = 0x000;
    pub const sd_arg: u32 = 0x008;
    pub const sd_stop: u32 = 0x010;
    pub const sd_seccnt: u32 = 0x014;
    pub const sd_rsp10: u32 = 0x018;
    pub const sd_rsp32: u32 = 0x020;
    pub const sd_rsp54: u32 = 0x028;
    pub const sd_rsp76: u32 = 0x030;
    pub const sd_info1: u32 = 0x038;
    pub const sd_info2: u32 = 0x03C;
    pub const sd_option: u32 = 0x050;
    pub const sd_buf0: u32 = 0x060;
    pub const soft_rst: u32 = 0x1C0;
};

/// The status bits the firmware polls.
pub const status = struct {
    /// SD_INFO1.RSPEND, a response was received.
    pub const rspend: u32 = 0x0000_0001;
    /// SD_INFO2.BRE, the read buffer holds a block.
    pub const bre: u32 = 0x0000_0100;
    /// SD_INFO2.BWE, the write buffer has room.
    pub const bwe: u32 = 0x0000_0200;
};

/// SD_OPTION's bus-width selectors, and what they decode to.
pub const option = struct {
    pub const width_1bit: u32 = 0x0000_8000;
    pub const width_8bit: u32 = 0x0000_2000;
};

/// SOFT_RST bit 0: clear asserts reset, set releases it.
pub const soft_rst = struct {
    pub const release: u32 = 0x0000_0001;
};

/// The commands the engine decodes. The index is the low six bits of
/// SD_CMD.
pub const cmd = struct {
    pub const go_idle: u32 = 0;
    pub const send_cid: u32 = 2;
    pub const send_rca: u32 = 3;
    pub const select: u32 = 7;
    pub const if_cond: u32 = 8;
    pub const send_csd: u32 = 9;
    pub const stop: u32 = 12;
    pub const set_blocklen: u32 = 16;
    pub const read_single: u32 = 17;
    pub const read_multi: u32 = 18;
    pub const write_single: u32 = 24;
    pub const write_multi: u32 = 25;
    pub const op_cond: u32 = 41;
    pub const app_cmd: u32 = 55;
    pub const index_mask: u32 = 0x3F;
};

const words = win_span / 4;

pub const Sdhi = struct {
    regs: [words]u32 = @splat(0),
    card: line.Line = line.absent,
    /// The block in flight, if a data phase is armed.
    data: xfer.Transfer = .{},
    /// CMD55 arrived and the next command is an ACMD.
    app_pending: bool = false,
    in_reset: bool = false,

    reads: u32 = 0,
    writes: u32 = 0,
    /// Data commands refused because the card was not selected.
    out_of_state: u32 = 0,
    /// Commands refused because SOFT_RST was asserted.
    while_reset: u32 = 0,
    /// Stores refused to a response register.
    faked: u32 = 0,
    /// FIFO accesses with no data phase in flight.
    starved: u32 = 0,
    /// FIFO accesses narrower than the port.
    narrow: u32 = 0,
    /// Blocks the card refused, each of which ended its data phase.
    lost: u32 = 0,

    pub fn init() Sdhi {
        var self = Sdhi{};
        self.regs[soft_rst_word] = soft_rst.release;
        return self;
    }

    /// A run that never touched the controller says nothing.
    pub fn quiet(self: *const Sdhi) bool {
        return self.reads == 0 and self.writes == 0 and self.out_of_state == 0 and
            self.while_reset == 0 and self.faked == 0 and self.starved == 0 and
            self.narrow == 0 and self.lost == 0 and self.card.held() == 0;
    }

    /// Lanes SD_OPTION currently asks for.
    pub fn lanes(self: *const Sdhi) u32 {
        const opt = self.regs[word(off.sd_option)];
        if (opt & option.width_1bit != 0) return 1;
        if (opt & option.width_8bit != 0) return 8;
        return 4;
    }

    pub fn read(self: *Sdhi, at: u32, width: u3) u32 {
        const offset = at - win_base;
        const aligned = offset & ~@as(u32, 3);
        if (aligned == off.sd_buf0) return self.fifoRead(width);
        if (word(aligned) >= words) return 0;
        return bus_lanes.part(self.regs[word(aligned)], offset & 3, width);
    }

    pub fn write(self: *Sdhi, at: u32, width: u3, value: u32) void {
        const offset = at - win_base;
        const aligned = offset & ~@as(u32, 3);
        if (aligned == off.sd_buf0) return self.fifoWrite(width, value);
        if (word(aligned) >= words) return;
        if (isResponse(aligned)) {
            self.faked += 1;
            return;
        }
        const merged = bus_lanes.merge(self.regs[word(aligned)], offset & 3, width, value);
        if (aligned == off.sd_info1 or aligned == off.sd_info2) return self.acknowledge(aligned, merged);
        if (aligned == off.soft_rst) return self.reset(merged);
        self.regs[word(aligned)] = merged;
        // SD_CMD is a 16-bit register: only a store that names its low half
        // issues. A store to the two bytes above it is shadowed.
        if (aligned == off.sd_cmd and offset & 3 == 0) self.issue(merged);
    }

    /// A store to a status register clears the flags it writes as zero and
    /// cannot raise one the controller did not set. Writing a one back is
    /// how the driver leaves a flag alone, so it is not an error.
    fn acknowledge(self: *Sdhi, aligned: u32, value: u32) void {
        self.regs[word(aligned)] &= value;
    }

    /// SOFT_RST: bit 0 clear holds the controller in reset, and the release
    /// leaves an engine with nothing in flight.
    fn reset(self: *Sdhi, value: u32) void {
        self.regs[word(off.soft_rst)] = value;
        self.in_reset = value & soft_rst.release == 0;
        self.data.stop();
        self.app_pending = false;
        self.regs[word(off.sd_info1)] = 0;
        self.regs[word(off.sd_info2)] = 0;
    }

    /// One command, latched from SD_CMD with SD_ARG already in place.
    fn issue(self: *Sdhi, value: u32) void {
        if (self.in_reset) {
            self.while_reset += 1;
            return;
        }
        const index = value & cmd.index_mask;
        const arg = self.regs[word(off.sd_arg)];
        const was_app = self.app_pending;
        self.app_pending = index == cmd.app_cmd;
        var rsp = [4]u32{ line.response.r1_ready, 0, 0, 0 };
        switch (index) {
            cmd.read_single, cmd.read_multi => self.beginRead(index == cmd.read_multi, arg, &rsp),
            cmd.write_single, cmd.write_multi => self.beginWrite(index == cmd.write_multi, arg, &rsp),
            cmd.stop => self.halt(),
            else => self.identify(index, arg, was_app, &rsp),
        }
        self.publish(rsp);
    }

    /// CMD12: the transfer ends here, and the buffer flag goes with it. A
    /// flag left standing over a stopped phase would have a polling driver
    /// reading a FIFO with nothing behind it.
    fn halt(self: *Sdhi) void {
        self.data.stop();
        self.regs[word(off.sd_info2)] &= ~(status.bre | status.bwe);
    }

    /// The identification and addressing commands, and the card state each
    /// one moves through.
    fn identify(self: *Sdhi, index: u32, arg: u32, was_app: bool, rsp: *[4]u32) void {
        if (index == cmd.op_cond and was_app) {
            self.card.powerUp();
            rsp[0] = line.response.ocr_ready;
            return;
        }
        switch (index) {
            cmd.go_idle => self.card.goIdle(),
            cmd.if_cond => rsp[0] = line.response.r7_if_cond,
            cmd.app_cmd => rsp[0] = line.response.r1_ready | line.response.r1_app_cmd,
            cmd.send_cid => {
                if (!self.card.publishCid()) return illegal(rsp);
                rsp.* = @splat(line.response.cid_word);
            },
            cmd.send_rca => {
                if (!self.card.takeAddress()) return illegal(rsp);
                rsp[0] = line.response.rca_value;
            },
            cmd.select => self.card.select(@intCast(arg >> 16)),
            cmd.send_csd => rsp.* = self.card.csd(),
            else => {},
        }
    }

    fn beginRead(self: *Sdhi, multi: bool, arg: u32, rsp: *[4]u32) void {
        if (!self.card.canTransfer()) {
            self.out_of_state += 1;
            return illegal(rsp);
        }
        self.data.arm(.read, arg, self.transferCount(multi));
        // A card that refuses the first block arms nothing, so BRE never
        // comes up and the driver is not served a block of zeros.
        if (!fifo.load(&self.data, self.card)) {
            self.lost += 1;
            return;
        }
        self.regs[word(off.sd_info2)] |= status.bre;
    }

    fn beginWrite(self: *Sdhi, multi: bool, arg: u32, rsp: *[4]u32) void {
        if (!self.card.canTransfer()) {
            self.out_of_state += 1;
            return illegal(rsp);
        }
        self.data.arm(.write, arg, self.transferCount(multi));
        self.regs[word(off.sd_info2)] |= status.bwe;
    }

    fn transferCount(self: *const Sdhi, multi: bool) u32 {
        if (!multi) return 1;
        return self.regs[word(off.sd_seccnt)];
    }

    fn publish(self: *Sdhi, rsp: [4]u32) void {
        self.regs[word(off.sd_rsp10)] = rsp[0];
        self.regs[word(off.sd_rsp32)] = rsp[1];
        self.regs[word(off.sd_rsp54)] = rsp[2];
        self.regs[word(off.sd_rsp76)] = rsp[3];
        self.regs[word(off.sd_info1)] |= status.rspend;
    }

    fn fifoRead(self: *Sdhi, width: u3) u32 {
        const served = fifo.read(&self.data, self.card, width);
        switch (served.outcome) {
            .narrow => self.narrow += 1,
            .starved => self.starved += 1,
            .word => {},
            .block => self.reads += 1,
            .ended => {
                self.reads += 1;
                self.clear(status.bre);
            },
            // The block that word finished was real; the next one was not.
            .lost => {
                self.reads += 1;
                self.lost += 1;
                self.clear(status.bre);
            },
        }
        return served.value;
    }

    fn fifoWrite(self: *Sdhi, width: u3, value: u32) void {
        switch (fifo.write(&self.data, self.card, width, value)) {
            .narrow => self.narrow += 1,
            .starved => self.starved += 1,
            .word => {},
            .block => self.writes += 1,
            .ended => {
                self.writes += 1;
                self.clear(status.bwe);
            },
            .lost => {
                self.lost += 1;
                self.clear(status.bwe);
            },
        }
    }

    /// Take a buffer flag down, so a polling driver is not left waiting on a
    /// FIFO with nothing behind it.
    fn clear(self: *Sdhi, flag: u32) void {
        self.regs[word(off.sd_info2)] &= ~flag;
    }

    pub fn block(self: *Sdhi) periph.Block {
        return .{
            .name = "SDHI0",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

const soft_rst_word = off.soft_rst / 4;

fn word(offset: u32) u32 {
    return offset / 4;
}

/// The response registers a card fills in and firmware may only read.
fn isResponse(aligned: u32) bool {
    return aligned == off.sd_rsp10 or aligned == off.sd_rsp32 or
        aligned == off.sd_rsp54 or aligned == off.sd_rsp76;
}

/// The card understood the command and refused it in this state.
fn illegal(rsp: *[4]u32) void {
    rsp[0] = line.response.r1_ready | line.response.r1_illegal;
}

fn readThunk(context: *anyopaque, at: u32, width: u3) u32 {
    const self: *Sdhi = @ptrCast(@alignCast(context));
    return self.read(at, width);
}

fn writeThunk(context: *anyopaque, at: u32, width: u3, value: u32) void {
    const self: *Sdhi = @ptrCast(@alignCast(context));
    self.write(at, width, value);
}

/// The address of a register in this window, so a test does not do the
/// arithmetic itself.
pub fn address(offset: u32) u32 {
    return win_base + offset;
}
