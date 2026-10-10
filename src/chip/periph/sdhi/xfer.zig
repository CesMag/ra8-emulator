//! The data phase behind SD_BUF0: one 512-byte block at a time, a word per
//! FIFO access.
//!
//! Its own file for the reason dmac/xfer.zig and dtc/xfer.zig are: the
//! window in sdhi.zig owns registers, flags and what a command means, and
//! this owns the block being served or filled and where the transfer has
//! got to. Neither has to carry the other.
const std = @import("std");
const sd_line = @import("line.zig");

pub const words_per_block = sd_line.block_bytes / 4;

/// Which direction the phase runs in, if one is in flight at all.
pub const Phase = enum { none, read, write };

/// One word out of the staged block, and whether that word finished it.
pub const Word = struct {
    value: u32,
    done: bool,
};

pub const Transfer = struct {
    phase: Phase = .none,
    stage: [sd_line.block_bytes]u8 = @splat(0),
    word_idx: u32 = 0,
    lba: u32 = 0,
    blocks_left: u32 = 0,

    /// Arm a phase at `lba` for `blocks` blocks. A count of zero is one
    /// block, which is what dev does and what a driver that forgot
    /// SD_SECCNT means.
    pub fn arm(self: *Transfer, phase: Phase, lba: u32, blocks: u32) void {
        self.phase = phase;
        self.lba = lba;
        self.blocks_left = @max(blocks, 1);
        self.word_idx = 0;
        @memset(&self.stage, 0);
    }

    pub fn stop(self: *Transfer) void {
        self.phase = .none;
        self.word_idx = 0;
        self.blocks_left = 0;
    }

    /// One word out of the staged block.
    pub fn pop(self: *Transfer) Word {
        const base = self.word_idx * 4;
        const value = std.mem.readInt(u32, self.stage[base..][0..4], .little);
        self.word_idx += 1;
        return .{ .value = value, .done = self.word_idx == words_per_block };
    }

    /// One word into the staged block. True when that word filled it.
    pub fn push(self: *Transfer, value: u32) bool {
        const base = self.word_idx * 4;
        std.mem.writeInt(u32, self.stage[base..][0..4], value, .little);
        self.word_idx += 1;
        return self.word_idx == words_per_block;
    }

    /// A block finished. A multi-block transfer moves to the next address
    /// and says so; the last one ends the phase.
    pub fn advance(self: *Transfer) bool {
        if (self.blocks_left > 0) self.blocks_left -= 1;
        self.word_idx = 0;
        if (self.blocks_left > 0) {
            self.lba +%= 1;
            return true;
        }
        self.phase = .none;
        return false;
    }
};
