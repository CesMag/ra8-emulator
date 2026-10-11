//! The SD card on the SPI line: the SPI-mode command set a card answers, and
//! the difference between a card that was brought up and one that was not.
//!
//! The driver clocks one byte at a time through SPDR: a six-byte command
//! frame goes out, the card answers R1, and a block arrives behind a data
//! token with a CRC16 after it. There is no chip select in this tree, so a
//! command self-frames off its `01xxxxxx` lead bits, which is what dev does
//! too and what the firmware's own `ra8_sdmmc_spi` driver makes work.
//!
//! Ported from board_periph_sd.c on dev, with five things that model does
//! not do.
//!
//! A DATA COMMAND NEEDS A CARD THAT CAME UP. dev answers CMD17 with a real
//! block, and CMD24 with a ready R1, from reset: the initialisation sequence
//! its own header documents (CMD0, CMD8, CMD55 + ACMD41) changes nothing it
//! checks. An image that skips or fumbles bring-up reads plausible blocks
//! there and nothing on silicon. Here a transfer command before ACMD41 has
//! completed is refused with an idle R1 and no data token, and counted.
//!
//! A BLOCK PAST THE END OF THE CARD IS NOT A BLOCK. dev zero-fills anything
//! past the image and hands it over behind a success token, so a run reading
//! off the end of a short card gets clean zeros and believes them. Here the
//! read is answered with the parameter-error R1 and the read data-error
//! token, the write is refused, and both are counted.
//!
//! THE BLOCK CRC IS CHECKED ONLY ONCE THE HOST ASKS FOR IT. A card in SPI
//! mode comes up with CRC checking OFF and CMD59 is what turns it on, so the
//! two bytes behind a write payload are not a checksum until the host has
//! said they are. dev swallows them without looking and always answers
//! "accepted", which is right by accident and wrong on purpose: a host that
//! did send CMD59 is then told a corrupt block is safe. Checking them
//! unconditionally is the other error, and the one this model made: a host
//! that never sent CMD59 and parks a placeholder in those two bytes, which
//! the spec lets it do, had every block refused. Here CMD59 latches the
//! flag, a mismatch is refused with the CRC-error data response only while
//! the flag is set, and a block taken with an unchecked checksum is counted
//! so the report says the model let one through.
//!
//! THIS MOVES NO IMAGE IN THE TREE TODAY, and the commit says so. The one
//! driver here, `ra8_sdmmc_spi`, never sends CMD59 but does compute a real
//! CRC16 over the payload before it clocks the two bytes out
//! (ra8_sdmmc_spi_io.c around the write block), so the old unconditional
//! check happened to agree with it every time. The two idle bytes in that
//! file are the READ path, where the driver clocks 0xFF twice to take the
//! card's own CRC16 and verify it; that direction is untouched, and the card
//! still always sends a real checksum.
//!
//! AN ERASE NEEDS A RANGE. CMD32 and CMD33 latch the bounds and CMD38
//! performs it; dev's bounds power up at zero and its `end >= start` test
//! passes, so a bare CMD38 with no range ever latched erases block zero, the
//! one block a filesystem cannot afford to lose. Here CMD38 without both
//! bounds is refused and counted.
//!
//! ONE CARD, ONE LINE. dev's card is a single global that SPI0, SPI1 and SCI
//! in SPI mode all clock into, so two channels talking at once interleave
//! into one command framer and neither notices. Here the card is attached to
//! one channel, and that is the model's own rule rather than a register:
//! nothing in this tree says which chip select the card sits on.
//!
//! NOT MODELLED, AND NOT GUESSED: the command CRC7 (the driver sends the two
//! frames that need one with a valid checksum and no test sends a bad one),
//! CMD6 switch, the SD status commands, and card detect or write protect,
//! which are pins rather than protocol. The capacity is the image's own,
//! declared there.
const std = @import("std");
pub const image = @import("../image.zig");
const sd_reply = @import("../reply.zig");
const sd_write = @import("../write.zig");
const sd_trace = @import("../trace.zig");
const sd_command = @import("../command.zig");
const spi = @import("ra8_chip").periph.spi;
pub const line = @import("line.zig");
pub const command = @import("../command.zig");
pub const crc = @import("../crc.zig");
pub const dump = @import("../dump.zig");
pub const fat = @import("../fat.zig");
pub const format = @import("../format.zig");
pub const format_advice = @import("../format_advice.zig");
pub const dirent = @import("../dirent.zig");
pub const mkimage = @import("../mkimage.zig");
pub const reply = @import("../reply.zig");
pub const trace = @import("../trace.zig");
pub const write = @import("../write.zig");
pub const bus_card = @import("../bus_card.zig");
pub const bus_line = @import("../bus_line.zig");
pub const snapshot = @import("../snapshot.zig");

/// Which SPI_B channel the card is wired to. The model's own rule; see the
/// header.
pub const line_channel: usize = 0;

/// A command frame, as it arrives on the line.
pub const frame = struct {
    pub const length: usize = 6;
    /// The lead bits that open a command: 01xxxxxx.
    pub const start_bits: u8 = 0x40;
    pub const start_mask: u8 = 0xC0;
    /// The command index in the lead byte.
    pub const index_mask: u8 = 0x3F;
};

/// The wire bytes and the staged reply both live next door, so a caller
/// reaches them through one name rather than two.
pub const Command = sd_command.Command;
pub const token = sd_reply.token;
pub const r1 = sd_reply.r1;

pub const csd = @import("../csd.zig");

pub const Card = struct {
    img: image.Image,
    /// Mid command frame.
    collecting: bool = false,
    cmd: [frame.length]u8 = @splat(0),
    cmd_len: usize = 0,
    /// The last command was CMD55, so the next one is an ACMD.
    app_cmd: bool = false,
    /// ACMD41 has completed: the card is out of idle.
    ready: bool = false,
    /// CMD59: a card in SPI mode starts with data-block CRC checking off.
    crc_checks: bool = false,
    /// The reply the host is part way through clocking out.
    reply: sd_reply.Reply = .{},
    /// An open CMD18 stream, and the block it hands over next.
    stream: bool = false,
    stream_block: u32 = 0,
    write: sd_write.Write = .{},
    /// The bounds CMD32 and CMD33 latch. Null until one is latched, which is
    /// the whole of the erase divergence.
    erase_lo: ?u32 = null,
    erase_hi: ?u32 = null,
    /// Blocks handed out, blocks taken, and blocks an erase gave back.
    reads: u32 = 0,
    writes: u32 = 0,
    erased: u32 = 0,
    /// Command frames the card completed.
    commands: u32 = 0,
    /// Transfer commands refused because the card was never brought up.
    uninit: u32 = 0,
    /// Blocks addressed past the end of the card.
    past_end: u32 = 0,
    /// Write payloads whose checksum did not match.
    crc_rejects: u32 = 0,
    /// Blocks taken whose checksum did not match, with checking switched off.
    crc_unchecked: u32 = 0,
    /// CMD38 with no range latched.
    erase_seq: u32 = 0,
    /// Write one line per command to stderr. Off unless --trace-sd asked.
    trace: bool = false,

    pub fn init(allocator: std.mem.Allocator) Card {
        return .{ .img = image.Image.init(allocator) };
    }

    pub fn deinit(self: *Card) void {
        self.img.deinit();
    }

    pub fn quiet(self: *const Card) bool {
        return self.commands == 0 and self.reads == 0 and self.writes == 0 and
            self.crc_unchecked == 0;
    }

    /// One byte out, one byte back: the whole of the card's side of the wire.
    pub fn exchange(self: *Card, tx: u8) u8 {
        if (self.reply.pending()) return self.reply.next();
        if (self.write.active()) return self.writeByte(tx);
        if (self.collecting) return self.collect(tx);
        if (tx & frame.start_mask == frame.start_bits) {
            self.collecting = true;
            self.cmd[0] = tx;
            self.cmd_len = 1;
            return token.idle;
        }
        // An open stream: the host clocking idle is asking for the next
        // block. The lead-bit check stays ahead of this so a CMD12 frame
        // interrupts the stream instead of being swallowed as clocking.
        if (self.stream) return self.streamNext();
        return token.idle;
    }

    /// The seam the SPI channel drives the card through.
    pub fn device(self: *Card) spi.Device {
        return .{ .context = self, .exchangeFn = exchangeThunk };
    }

    fn collect(self: *Card, tx: u8) u8 {
        self.cmd[self.cmd_len] = tx;
        self.cmd_len += 1;
        if (self.cmd_len >= frame.length) {
            self.collecting = false;
            self.process();
        }
        return token.idle;
    }

    fn process(self: *Card) void {
        const index: u8 = self.cmd[0] & frame.index_mask;
        const arg = std.mem.readInt(u32, self.cmd[1..5], .big);
        const was_app = self.app_cmd;
        const status: u8 = if (self.ready) r1.ready else r1.idle;
        self.app_cmd = false;
        self.commands +%= 1;
        const cmd: Command = @fromBackingInt(@intCast(index));
        if (self.trace) {
            var buf: sd_trace.Buffer = undefined;
            std.debug.print("{s}\n", .{sd_trace.line(&buf, index, arg, was_app)});
        }
        if (cmd == .app_op_cond and was_app) {
            self.ready = true;
            self.reply.one(r1.ready);
            return;
        }
        if (self.dispatchIdent(cmd, arg, status)) return;
        self.dispatchData(cmd, arg, status);
    }

    /// Bring-up and configuration: the commands that say who the card is.
    fn dispatchIdent(self: *Card, cmd: Command, arg: u32, status: u8) bool {
        switch (cmd) {
            .go_idle => self.reply.one(r1.idle),
            // R7: R1 then the voltage range and the 0xAA check pattern back.
            .send_if_cond => self.reply.tail(r1.idle, .{ 0, 0, 1, 0xAA }),
            .app_cmd => {
                self.app_cmd = true;
                self.reply.one(r1.idle);
            },
            // R3: R1 then OCR, power-up done with CCS set for a high-capacity
            // card and the 3.3V window.
            .read_ocr => self.reply.tail(status, .{ 0xC0, 0x00, 0x80, 0 }),
            .set_blocklen => self.reply.one(r1.ready),
            // CMD59: bit 0 of the argument switches data-block CRC
            // checking on. Nothing else in the argument is defined.
            .crc_on_off => {
                self.crc_checks = (arg & 1) != 0;
                self.reply.one(r1.ready);
            },
            else => return false,
        }
        return true;
    }

    /// Transfers and erases: the commands that move or lose data.
    fn dispatchData(self: *Card, cmd: Command, arg: u32, status: u8) void {
        switch (cmd) {
            .send_csd => self.sendCsd(),
            .read_single, .read_multi => self.beginRead(cmd == .read_multi, arg),
            .stop => self.stopRead(status),
            .write_single, .write_multi => self.beginWrite(cmd == .write_multi, arg, status),
            .erase_start => {
                self.erase_lo = arg;
                self.reply.one(status);
            },
            .erase_end => {
                self.erase_hi = arg;
                self.reply.one(status);
            },
            .erase => self.eraseRange(status),
            else => self.reply.one(status),
        }
    }

    fn beginRead(self: *Card, multi: bool, block: u32) void {
        self.stream = false;
        if (!self.ready) {
            self.uninit +%= 1;
            self.reply.one(r1.idle);
            return;
        }
        var payload: image.Block = undefined;
        if (!self.img.read(block, &payload)) {
            self.past_end +%= 1;
            self.reply.two(r1.parameter, token.read_error);
            return;
        }
        self.reply.block(&payload);
        self.reads +%= 1;
        self.stream = multi;
        self.stream_block = block +% 1;
    }

    /// The next block of an open CMD18 stream. Mid-stream blocks carry no R1:
    /// the card just sends the next data token.
    fn streamNext(self: *Card) u8 {
        var payload: image.Block = undefined;
        if (!self.img.read(self.stream_block, &payload)) {
            self.past_end +%= 1;
            self.stream = false;
            self.reply.one(token.read_error);
            return self.reply.next();
        }
        self.reply.block(&payload);
        self.reads +%= 1;
        self.stream_block +%= 1;
        // A block mid-stream carries no status byte.
        self.reply.skipStatus();
        return self.reply.next();
    }

    /// CMD12 closes a stream: a stuff byte the driver discards, R1, then one
    /// busy byte, which is how long a card holds the line after a stop.
    fn stopRead(self: *Card, status: u8) void {
        self.stream = false;
        self.reply.tail(token.idle, .{ status, token.busy, token.idle, token.idle });
        self.reply.len = 4;
    }

    fn beginWrite(self: *Card, multi: bool, block: u32, status: u8) void {
        if (!self.ready) {
            self.uninit +%= 1;
            self.reply.one(r1.idle);
            return;
        }
        self.reply.one(status);
        self.write.begin(block, multi);
    }

    fn writeByte(self: *Card, tx: u8) u8 {
        switch (self.write.feed(tx)) {
            .none => {},
            .stopped => {
                // Program time, then the line comes back up.
                self.reply.two(token.busy, token.idle);
            },
            .commit => |done| self.commit(done),
        }
        return token.idle;
    }

    fn commit(self: *Card, done: sd_write.Commit) void {
        if (!done.crc_ok) {
            if (self.crc_checks) {
                self.crc_rejects +%= 1;
                self.reply.dataResponse(token.crc_error);
                return;
            }
            self.crc_unchecked +%= 1;
        }
        if (!self.img.write(done.block, &self.write.buf)) {
            self.past_end +%= 1;
            self.reply.dataResponse(token.write_error);
            return;
        }
        self.writes +%= 1;
        self.reply.dataResponse(token.accepted);
    }

    fn eraseRange(self: *Card, status: u8) void {
        const lo = self.erase_lo orelse {
            self.erase_seq +%= 1;
            self.reply.one(r1.parameter);
            return;
        };
        const hi = self.erase_hi orelse {
            self.erase_seq +%= 1;
            self.reply.one(r1.parameter);
            return;
        };
        self.erase_lo = null;
        self.erase_hi = null;
        if (hi < lo) {
            self.reply.one(status);
            return;
        }
        if (!self.img.inRange(lo)) {
            self.past_end +%= 1;
            self.reply.one(r1.parameter);
            return;
        }
        const last = @min(hi, self.img.capacity_blocks - 1);
        self.erased +%= self.img.zero(lo, last);
        self.reply.one(status);
    }

    /// CMD9: a CSD v2.0 register whose capacity field is the image's own, so
    /// a driver sizing the card sees the card it actually gets.
    fn sendCsd(self: *Card) void {
        var block: [csd.length]u8 = @splat(0);
        block[0] = csd.version;
        const size = self.img.csize();
        block[csd.csize_high] = @intCast((size >> 16) & csd.high_mask);
        block[csd.csize_mid] = @intCast((size >> 8) & 0xFF);
        block[csd.csize_low] = @intCast(size & 0xFF);
        self.reply.block(&block);
    }
};

fn exchangeThunk(context: *anyopaque, tx: u8) u8 {
    const self: *Card = @ptrCast(@alignCast(context));
    return self.exchange(tx);
}
