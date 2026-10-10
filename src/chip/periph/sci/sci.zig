//! SCI_B: the serial channels, so a console print ends instead of spinning.
//!
//! The RA8D2 puts ten SCI_B channels at 0x4035_8000, 0x100 apart (HUM Ch 29,
//! ra8_sci_regs.h, the 32-bit-register variant). The EK-RA8D2 console is SCI8
//! on PD02/PD03, and it is the block every non-display example reaches first:
//! `ra8_sci_putc_polling` writes a byte and then waits on CSR.TDRE, and
//! `ra8_sci_getc_polling` waits on CSR.RDRF. Until now the window fell through
//! to the sparse register file, where a status poll gets alternating stand-in
//! values rather than a transmitter that drains, so console output was a race
//! against the instruction budget instead of a result. Ported from
//! board_periph_sci.c on dev.
//!
//!   RDR   (+0x00) receive data, RDAT[7:0]
//!   TDR   (+0x04) transmit data, TDAT[7:0]
//!   CCR0  (+0x08) RE, TE and the three interrupt enables
//!   CSR   (+0x48) TDRE, TEND, RDRF, RXDMON
//!   FRSR  (+0x50) receive-FIFO status
//!   FTSR  (+0x54) transmit-FIFO status
//!   CFCLR (+0x68) common flag clear, write-1-to-clear
//!   FFCLR (+0x70) FIFO flag clear, write-1-to-clear
//!
//! The transmitter is always drained here: there is no baud-rate clock in an
//! instruction-stepped emulator, so a byte written to TDR is captured and gone,
//! and TDRE/TEND read as set. The receiver is a host-fed ring per channel, so
//! RDRF is a fact about queued bytes rather than a value a driver wrote.
//!
//! THE SIMPLE LIN HALF OF THE WINDOW ANSWERS TOO. XCR0/XCR1/XCR2, XSR0/XSR1
//! and XFCLR sit in the same channel window and used to fall through the
//! `else` arms below: every store dropped, every read zero. XCR1.TCST is a
//! self-clearing strobe that starts a break field, so reading it back clear
//! is exactly what ra8_sci_lin_send_break polls for, and the call returned
//! success for a break that never happened. The rule and its evidence live
//! in src/chip/periph/sci/lin.zig.
//!
//! RDR AND TDR ARE A DATA PORT, AND THE PORT IS THE BYTE RDAT/TDAT SITS IN.
//! An access that does not name byte 0 of the word carries no character in
//! either direction. The store side always said so. The read side did not:
//! it popped the receive ring for any access landing anywhere in RDR, so a
//! driver loading one of the bytes above RDAT ate a received character, was
//! handed zero for it, and the run counted the byte as delivered while the
//! next read of RDAT starved. Both directions are refused and counted now,
//! and a refused read leaves the ring holding what it had, so the driver can
//! come back with a load that names the data.
const std = @import("std");
const Bounded = @import("../../core/bounded.zig").Bounded;
const periph = @import("../registry.zig");
const sci_status = @import("status.zig");
const sci_lin = @import("lin.zig");
const sci_spi = @import("spi.zig");
const sci_device = @import("device.zig");
const sci_ring = @import("ring.zig");
const sci_error = @import("error_latches.zig");
const lanes = @import("../lanes.zig");

/// SCI_B geometry. The Non-secure alias is folded onto this base by the bus
/// before anything here sees it.
pub const win_base: u32 = 0x4035_8000;
pub const stride: u32 = 0x100;
pub const channels: usize = 10;
pub const win_span: u32 = stride * channels;

/// The EK-RA8D2 console channel: SCI8, the one carrying UART text.
pub const console_channel: usize = 8;

pub const off_rdr: u32 = 0x00;
pub const off_tdr: u32 = 0x04;
pub const off_ccr0: u32 = 0x08;
/// CCR3's mode field, and what a Simple-SPI frame clocks back: spi.zig.
pub const off_ccr3: u32 = sci_spi.off_ccr3;
/// The status words and the clear strobes live in src/chip/periph/sci/status.zig,
/// which owns what they answer and what a store to one does.
pub const off_csr: u32 = sci_status.off.csr;
pub const off_frsr: u32 = sci_status.off.frsr;
pub const off_ftsr: u32 = sci_status.off.ftsr;
pub const off_cfclr: u32 = sci_status.off.cfclr;
pub const off_ffclr: u32 = sci_status.off.ffclr;

/// CCR0 enables (ra8_sci_ccr0_bit_t).
pub const ccr0 = struct {
    pub const re: u32 = 0x0000_0001;
    pub const te: u32 = 0x0000_0010;
    pub const rie: u32 = 0x0001_0000;
    pub const tie: u32 = 0x0010_0000;
    pub const teie: u32 = 0x0020_0000;
};

/// The Simple LIN registers, and what a store to one does.
pub const lin = sci_lin;

pub const csr = sci_status.csr;
pub const cfclr = sci_status.cfclr;
pub const Errors = sci_error.Errors;
pub const fifo = sci_status.fifo;

/// The ELC event numbers the console channel raises (HUM Ch 19 Table 19.3,
/// FSP `bsp_elc.h` for ra8d2: SCI8_RXI 0x122, _TXI 0x123, _TEI 0x124). A
/// firmware that routes one of these writes the same number into an IELSR
/// slot, and src/chip/periph/icu/icu.zig matches the raised event to that slot.
///
/// Only the console channel has modelled event numbers, the same limit dev
/// draws: the other nine channels raise nothing until something needs them.
pub const event = struct {
    pub const rxi: u16 = 0x122;
    pub const txi: u16 = 0x123;
    pub const tei: u16 = 0x124;
};

/// The console events armed and satisfied at one moment. Bounded because
/// there are exactly three of them.
pub const Due = Bounded(u16, 3);

pub const data_mask: u32 = 0xFF;

/// Model sizing, and the receive ring itself: src/chip/periph/sci/ring.zig.
pub const limits = sci_ring.limits;
pub const Ring = sci_ring.Ring;

/// Something on a channel's line, and when it is on it.
pub const Device = sci_device.Device;

/// One channel: the control shadow, the byte counters and the RX ring.
pub const Channel = struct {
    control: u32 = 0,
    transmitted: u32 = 0,
    received: u32 = 0,
    /// TDR writes made while CCR0.TE was clear, which silicon does not send.
    unsent: u32 = 0,
    /// Bytes a device on the line drove back while CCR0.RE was clear. A
    /// receiver that was never enabled hears nothing on silicon, so these
    /// are gone rather than waiting in the ring.
    unheard: u32 = 0,
    /// Stores aimed at CSR, FRSR or FTSR: the controller owns those words.
    status_stores: u32 = 0,
    /// Loads of RDR that named a byte above RDAT. They take nothing.
    unnamed_reads: u32 = 0,
    /// Stores to TDR that named a byte above TDAT. They send nothing.
    unnamed_stores: u32 = 0,
    rx: Ring = .{},
    /// The CSR flags firmware has to clear: src/chip/periph/sci/error_latches.zig.
    errors: sci_error.Errors = .{},
    /// CCR3, kept whole so the mode field can be read out of it.
    ccr3: u32 = 0,
    /// Simple-SPI frames nothing answered, clocked in off an idle line.
    idle_frames: u32 = 0,
    /// The Simple LIN half of this channel.
    lin: sci_lin.Lin = .{},
    /// What is on this channel's line, if anything.
    device: ?Device = null,

    pub fn enabled(self: *const Channel, bit: u32) bool {
        return self.control & bit != 0;
    }

    pub fn quiet(self: *const Channel) bool {
        return self.transmitted == 0 and self.received == 0 and
            self.unsent == 0 and self.unheard == 0 and self.status_stores == 0 and
            self.unnamed_reads == 0 and self.unnamed_stores == 0 and
            self.idle_frames == 0 and
            self.errors.quiet() and self.lin.quiet();
    }

    /// CSR as this channel answers it. What those bits mean, and why they
    /// read the way they do, is src/chip/periph/sci/status.zig's.
    pub fn status(self: *const Channel) u32 {
        return sci_status.common(self.readable()) | self.errors.flags();
    }

    /// Take bytes off the line into the ring, raising the overrun latch when
    /// the ring could not hold them all.
    pub fn receive(self: *Channel, data: []const u8) void {
        if (self.rx.push(data)) self.errors.raiseOverrun();
    }

    pub fn readable(self: *const Channel) bool {
        return self.enabled(ccr0.re) and !self.rx.empty();
    }
};

/// The captured console line, and what it does with one that never ends,
/// live in src/chip/periph/sci/line.zig.
pub const Line = @import("line.zig").Line;

/// What a watcher outside the run sees of every sent byte (RA8EMU-206).
pub const Tap = @import("tap.zig").Tap;

/// The block: ten channels and the console line capture.
pub const Sci = struct {
    channels: [channels]Channel = @splat(.{}),
    line: Line = .{},
    tap: ?Tap = null,

    pub fn init() Sci {
        return .{};
    }

    pub fn quiet(self: *const Sci) bool {
        for (&self.channels) |*channel| {
            if (!channel.quiet()) return false;
        }
        return true;
    }

    pub fn console(self: *Sci) *Channel {
        return &self.channels[console_channel];
    }

    /// Queue host bytes for the firmware to read out of RDR.
    pub fn feed(self: *Sci, channel: usize, data: []const u8) void {
        if (channel >= channels) return;
        self.channels[channel].receive(data);
    }

    /// Put a device on one channel's line.
    pub fn attachDevice(self: *Sci, channel: usize, on_line: Device) void {
        if (channel >= channels) return;
        self.channels[channel].device = on_line;
    }

    /// The console events that are due right now. The transmitter is always
    /// drained in this model, so TXI and TEI are due whenever the firmware has
    /// their enables set alongside TE; RXI is due only while the receiver is
    /// enabled and a host byte is actually queued. Raised at the chunk
    /// boundary by whoever owns the event links, which keeps this file free of
    /// any knowledge of the interrupt controller.
    pub fn dueEvents(self: *const Sci) Due {
        var due = Due{};
        const channel = &self.channels[console_channel];
        if (channel.enabled(ccr0.te)) {
            if (channel.enabled(ccr0.tie)) due.appendAssumeCapacity(event.txi);
            if (channel.enabled(ccr0.teie)) due.appendAssumeCapacity(event.tei);
        }
        if (channel.enabled(ccr0.rie) and channel.readable()) due.appendAssumeCapacity(event.rxi);
        return due;
    }

    /// A read of any width. The window is 32-bit registers, so the access is
    /// served from the word it lands in and then cut to the bytes it names:
    /// TDRE is bit 29, and a driver polling it with a byte load reads CSR+3.
    pub fn read(self: *Sci, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        const index = offset / stride;
        if (index >= channels) return 0;
        const local = offset % stride;
        const at = lanes.lane(local);
        const word = self.readRegister(@intCast(index), lanes.word(local), at);
        return lanes.part(word, at, width);
    }

    fn readRegister(self: *Sci, index: usize, offset: u32, at: u32) u32 {
        const channel = &self.channels[index];
        return switch (offset) {
            off_rdr => self.readData(index, at),
            off_ccr0 => channel.control,
            off_ccr3 => channel.ccr3,
            off_csr => channel.status(),
            off_frsr => sci_status.receive(channel.readable()),
            off_ftsr => sci_status.transmit,
            // The clear strobes are write-only, and nothing else in the
            // channel answers: zero beats the sparse file's alternating
            // stand-in here, because these are registers with no value.
            else => if (sci_lin.owns(offset)) channel.lin.read(offset) else 0,
        };
    }

    /// RDR takes the oldest queued byte, and only for an access that names
    /// RDAT. A load of a byte above it leaves the ring alone: taking a
    /// character for a read that cannot carry it loses the character. A read
    /// with the receiver disabled, or with nothing queued, reads zero and is
    /// not counted as received.
    fn readData(self: *Sci, index: usize, at: u32) u32 {
        const channel = &self.channels[index];
        if (at != 0) {
            channel.unnamed_reads +%= 1;
            return 0;
        }
        if (!channel.readable()) return 0;
        const byte = channel.rx.pop() orelse return 0;
        channel.received += 1;
        return byte;
    }

    /// A store of any width, judged on the word it lands in and on the byte
    /// lanes it actually names.
    pub fn write(self: *Sci, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        const index = offset / stride;
        if (index >= channels) return;
        const local = offset % stride;
        self.writeRegister(@intCast(index), lanes.word(local), lanes.lane(local), width, value);
    }

    fn writeRegister(self: *Sci, index: usize, word: u32, lane: u32, width: u3, value: u32) void {
        const channel = &self.channels[index];
        if (sci_status.readOnly(word)) {
            channel.status_stores +%= 1;
            return;
        }
        switch (word) {
            // TDAT is TDR[7:0]. A narrow store that does not name that byte
            // carries no character, and the bits above it are the parity and
            // multiprocessor fields nothing here interprets.
            off_tdr => if (lane == 0)
                self.writeData(index, @truncate(value & data_mask))
            else {
                channel.unnamed_stores +%= 1;
            },
            // A narrow store leaves the bytes it does not name where they
            // were, so setting RE with a byte store to CCR0+0 keeps the
            // interrupt enables sitting in the bytes above it.
            off_ccr0 => channel.control = lanes.merge(channel.control, lane, width, value),
            off_ccr3 => channel.ccr3 = lanes.merge(channel.ccr3, lane, width, value),
            // CFCLR is write-1-to-clear. Most of what it names this model
            // derives rather than latches, so clearing those changes nothing;
            // ORER is the one real latch, and the bit comes out of the value
            // the access carries, never out of a shadow this register has not
            // got.
            off_cfclr => channel.errors.clear(lanes.merge(0, lane, width, value)),
            // FFCLR clears FRSR.DR, which follows the queue here.
            else => if (sci_lin.owns(word)) channel.lin.write(word, lane, width, value),
        }
    }

    /// A byte handed to the transmitter. With CCR0.TE clear the transmitter is
    /// not running, so the frame is never launched: the write is counted and
    /// dropped, which is what silicon does and what the emulator used to hide.
    fn writeData(self: *Sci, index: usize, byte: u8) void {
        const channel = &self.channels[index];
        if (!channel.enabled(ccr0.te)) {
            channel.unsent += 1;
            return;
        }
        channel.transmitted += 1;
        if (index == console_channel) self.line.feed(byte);
        if (self.tap) |tap| tap.sent(tap.ctx, index, byte);
        self.deliver(index, byte);
    }

    /// Hand a sent byte to whatever is on the line and queue what it drives
    /// back. A reply arriving with CCR0.RE clear is lost, not banked: the
    /// receiver is not running, and an emulator that queues it anyway lets a
    /// driver that never enabled the receiver read its answers later and
    /// pass a run it would fail on the bench.
    fn deliver(self: *Sci, index: usize, byte: u8) void {
        const channel = &self.channels[index];
        const on_line = channel.device orelse return self.clockIdle(index);
        // A device wired to the channel's SPI pins is not on the line while
        // the channel is running as a UART (src/chip/periph/sci/device.zig).
        if (on_line.spi_only and !sci_spi.simpleSpi(channel.ccr3)) return self.clockIdle(index);
        const reply = on_line.feed(byte);
        if (reply.len == 0) return self.clockIdle(index);
        if (!channel.enabled(ccr0.re)) {
            channel.unheard +%= @intCast(reply.len);
            return;
        }
        channel.receive(reply);
    }

    /// A Simple-SPI frame nothing answered still clocked one in: the channel
    /// drives the clock, so the receiver shifts the level the line sat at,
    /// and an unconnected CIPO sits high. Asynchronous channels are untouched.
    fn clockIdle(self: *Sci, index: usize) void {
        const channel = &self.channels[index];
        if (!sci_spi.simpleSpi(channel.ccr3)) return;
        channel.idle_frames +%= 1;
        if (!channel.enabled(ccr0.re)) {
            channel.unheard +%= 1;
            return;
        }
        channel.receive(&[_]u8{sci_spi.idle_byte});
    }

    pub fn block(self: *Sci) periph.Block {
        return .{
            .name = "SCI_B UART",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
            .peekFn = @import("peek.zig").thunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Sci = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Sci = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}

/// The address of one register on one channel, so a test or a later slice does
/// not have to do the arithmetic itself.
pub fn regAddress(channel: usize, offset: u32) u32 {
    return win_base + @as(u32, @intCast(channel)) * stride + offset;
}
