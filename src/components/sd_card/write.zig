//! The data phase of an SD block write in SPI mode: the token the host sends
//! ahead of a block, the 512 payload bytes, and the two CRC bytes behind them.
//!
//! Split out of sd_card.zig the way sdhi/xfer.zig is split out of sdhi.zig.
//! The card owns commands and responses; this owns the bytes in between, and
//! it decides nothing about the image: a finished block is handed back as an
//! outcome and the card commits it, so the store and the protocol stay apart.
const image = @import("image.zig");
const sd_crc = @import("crc.zig");

/// Where a write is between the command and the card's data response.
pub const Phase = enum {
    /// Not in a write at all.
    idle,
    /// Waiting for the data-start token, or the stop-tran that ends a
    /// multi-block write.
    token,
    /// Taking the 512 payload bytes.
    data,
    /// Taking the two CRC bytes behind them.
    crc,
};

/// The tokens the host sends on this path (SD physical layer, SPI mode).
pub const host_token = struct {
    /// Data-start for a single block, and for a read the card stages.
    pub const data: u8 = 0xFE;
    /// Data-start for one block of a multi-block write.
    pub const multi: u8 = 0xFC;
    /// Stop-tran: the multi-block write ends here.
    pub const stop: u8 = 0xFD;
};

/// A block the host has finished sending, with the verdict on its checksum.
pub const Commit = struct {
    block: u32,
    crc_ok: bool,
};

/// What feeding one byte did.
pub const Outcome = union(enum) {
    /// Still collecting.
    none,
    /// A whole block arrived; `buf` holds it.
    commit: Commit,
    /// A stop-tran ended a multi-block write.
    stopped,
};

pub const Write = struct {
    phase: Phase = .idle,
    multi: bool = false,
    /// The block this payload is for.
    block: u32 = 0,
    /// Payload bytes taken, then CRC bytes taken.
    count: usize = 0,
    /// The checksum the host sent, assembled big-endian.
    sent: u16 = 0,
    buf: image.Block = @splat(0),

    pub fn active(self: *const Write) bool {
        return self.phase != .idle;
    }

    /// A command accepted: from here the bytes on the line are the payload,
    /// not commands.
    pub fn begin(self: *Write, block: u32, multi: bool) void {
        self.phase = .token;
        self.multi = multi;
        self.block = block;
        self.count = 0;
        self.sent = 0;
    }

    pub fn feed(self: *Write, tx: u8) Outcome {
        return switch (self.phase) {
            .token => self.takeToken(tx),
            .data => self.takeData(tx),
            .crc => self.takeCrc(tx),
            .idle => .none,
        };
    }

    /// A card waiting for a token ignores anything that is not one, which is
    /// how the host's idle clocking between command and payload passes.
    fn takeToken(self: *Write, tx: u8) Outcome {
        if (tx == host_token.data or tx == host_token.multi) {
            self.phase = .data;
            self.count = 0;
            return .none;
        }
        if (self.multi and tx == host_token.stop) {
            self.phase = .idle;
            self.multi = false;
            return .stopped;
        }
        return .none;
    }

    fn takeData(self: *Write, tx: u8) Outcome {
        self.buf[self.count] = tx;
        self.count += 1;
        if (self.count >= image.geometry.block_bytes) {
            self.phase = .crc;
            self.count = 0;
            self.sent = 0;
        }
        return .none;
    }

    fn takeCrc(self: *Write, tx: u8) Outcome {
        self.sent = (self.sent << 8) | tx;
        self.count += 1;
        if (self.count < 2) return .none;
        const done = Commit{ .block = self.block, .crc_ok = self.sent == sd_crc.crc16(&self.buf) };
        self.count = 0;
        if (self.multi) {
            self.block +%= 1;
            self.phase = .token;
        } else {
            self.phase = .idle;
        }
        return .{ .commit = done };
    }
};
