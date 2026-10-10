//! The receive FIFO behind a CAN-FD channel: the frames delivered to it, in
//! the order they arrived, and nothing once they have been taken.
//!
//! A CFDRF window is one frame's worth of registers, but the hardware behind
//! it is a queue: the controller fills stages while the firmware is busy, and
//! CFDRFPCTR advances to the next one. Holding that queue here rather than a
//! single slot is what makes an overrun visible instead of silent, and what
//! makes a pop of an empty FIFO something the model can refuse.
//!
//! Ported out of board_periph_canfd.c on dev, which keeps one slot: a second
//! delivery overwrites the first, so an image that transmits twice before
//! reading loses the older frame with nothing said about it.
const std = @import("std");

/// A frame as the CFDTM / CFDRF windows carry it: ID, PTR, the status or
/// control word, then the 64-byte data field. Nineteen words in all.
pub const frame_words: usize = 0x4C / 4;

/// How many frames RX FIFO 0 holds. CFDRFCC.RFDC picks the depth on silicon;
/// no header in this tree gives that field, so four is this model's own rule,
/// stated rather than read. dev holds one.
pub const depth: usize = 4;

/// The identifier fields, as dev's own masks name them.
pub const id_mask = struct {
    /// The 11-bit standard identifier.
    pub const standard: u32 = 0x0000_07FF;
    /// The 29-bit extended identifier.
    pub const extended: u32 = 0x1FFF_FFFF;
};

/// CFDTM/CFDRF.PTR: the timestamp low, the data-length code at the top.
pub const ptr = struct {
    /// PTR is the second word of a frame window.
    pub const word: usize = 1;
    pub const dlc_shift: u5 = 28;
    pub const dlc_mask: u32 = 0xF;
};

/// One frame, held as the words the window reads back so nothing is lost
/// between the transmit buffer and the receive stage.
pub const Frame = struct {
    words: [frame_words]u32 = @splat(0),

    pub fn id(self: *const Frame) u32 {
        return self.words[0] & id_mask.extended;
    }

    pub fn dlc(self: *const Frame) u32 {
        return (self.words[ptr.word] >> ptr.dlc_shift) & ptr.dlc_mask;
    }
};

/// The queue itself: a ring of stages, oldest first.
pub const Fifo = struct {
    stages: [depth]Frame = @splat(Frame{}),
    head: usize = 0,
    count: usize = 0,

    pub fn empty(self: *const Fifo) bool {
        return self.count == 0;
    }

    pub fn full(self: *const Fifo) bool {
        return self.count == depth;
    }

    pub fn len(self: *const Fifo) usize {
        return self.count;
    }

    /// Take a delivered frame. A full FIFO keeps what it has: on silicon the
    /// stage that never opened is the one that misses the frame, so the
    /// newest is what goes, and the caller counts it.
    pub fn push(self: *Fifo, frame: Frame) bool {
        if (self.full()) return false;
        self.stages[(self.head + self.count) % depth] = frame;
        self.count += 1;
        return true;
    }

    pub fn peek(self: *const Fifo) ?*const Frame {
        if (self.empty()) return null;
        return &self.stages[self.head];
    }

    /// Advance past the oldest frame. False when there was nothing to
    /// advance past, which is a pop the firmware had no business making.
    pub fn pop(self: *Fifo) bool {
        if (self.empty()) return false;
        self.head = (self.head + 1) % depth;
        self.count -= 1;
        return true;
    }

    /// One word of the frame the CFDRF window is showing. An empty FIFO
    /// shows nothing rather than the frame that was last taken out of it.
    pub fn word(self: *const Fifo, index: usize) u32 {
        if (index >= frame_words) return 0;
        const front = self.peek() orelse return 0;
        return front.words[index];
    }
};
