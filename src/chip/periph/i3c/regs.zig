//! The I3C channel's register window, and what an access of each width names
//! inside it.
//!
//! Split out of `src/chip/periph/i3c/i3c.zig`, which owns the transfer machine, the
//! device registry and the counters. This file owns the access rule alone.
//!
//! EVERY REGISTER IN THIS WINDOW IS A WORD (HUM Ch 40, ra8_i3c_regs.h): the
//! condition request at +0x140, the data port at +0x158, the bus status at
//! +0x1D0, the transfer status at +0x1E0, the bus-condition status at +0x210.
//! `i3c.zig` switched on the exact byte offset of an access and ignored its
//! width, and indexed its shadow by `offset / 4`, so a narrow access anywhere
//! inside a register was answered by, and landed on, the whole word. Three
//! things followed, all of them wrong on silicon.
//!
//! A NARROW READ ANSWERED THE WRONG LANE. A byte read of BST+1, which is how
//! a driver tests TENDF on its own, was served the whole status word cut to
//! its low byte: the START, STOP and NACK flags answering in place of the
//! transfer-end flag it asked for.
//!
//! A NARROW STORE OVERWROTE THE LANES IT DID NOT NAME. A byte store into the
//! third byte of a configuration register put its value at the bottom of the
//! word and cleared everything above it, so a driver writing one field of a
//! register it had already programmed lost the rest.
//!
//! AND AN ACK CLEARED FLAGS IT NEVER NAMED. BST is write-0-to-clear, so the
//! model ANDs the written value into it. A byte store carries zeros in the
//! twenty-four bits above the lane it names, and those zeros cleared TENDF at
//! b8, ALF at b16 and TODF at b20: a handler acknowledging the START
//! condition with a byte store wiped the transfer-end and arbitration-lost
//! flags on its way past, and the driver waiting on TENDF waited forever.
//!
//! The rule now is the bus's, the same one `src/chip/periph/lanes.zig` already
//! serves the PORT, SCI, ELC, ICU and DMAC windows: a read is served from the
//! word the access lands in and cut to the lanes it names, a narrow store is
//! merged into that word so the lanes it does not name keep what they had,
//! and a write-0-to-clear register is cleared only in the lanes the store
//! actually named.
const lanes = @import("../lanes.zig");
const flag = @import("flags.zig");

/// Whether a window-relative offset is one this block answers.
pub fn inside(offset: u32) bool {
    return offset < flag.win_span;
}

/// Where one bus access lands: the word it is served from, the byte of that
/// word it starts at, and how wide it is.
pub const Access = struct {
    word: u32,
    at: u32,
    width: u3,

    pub fn of(offset: u32, width: u3) Access {
        return .{ .word = lanes.word(offset), .at = lanes.lane(offset), .width = width };
    }

    /// The index of this access's word in a shadow held word by word.
    pub fn index(self: Access) usize {
        return self.word / 4;
    }

    /// The bits of the word this access names.
    pub fn mask(self: Access) u32 {
        return lanes.named(self.at, self.width);
    }

    /// Whether this access names byte `byte` of its word.
    pub fn names(self: Access, byte: u2) bool {
        const shift: u5 = @as(u5, byte) * 8;
        return self.mask() & (@as(u32, 0xFF) << shift) != 0;
    }

    /// What a read of this access answers, out of the whole word.
    pub fn cut(self: Access, value: u32) u32 {
        return lanes.part(value, self.at, self.width);
    }

    /// `value` folded into `current`, leaving the lanes this access does not
    /// name exactly where they were.
    pub fn fold(self: Access, current: u32, value: u32) u32 {
        return lanes.merge(current, self.at, self.width, value);
    }

    /// The mask a write-0-to-clear register is ANDed with for this store: the
    /// written zeros inside the lanes it names, ones everywhere else.
    pub fn clearing(self: Access, value: u32) u32 {
        return lanes.merge(~@as(u32, 0), self.at, self.width, value);
    }

    /// The data port moves one byte per access and that byte rides the low
    /// lane of the word, so an access that does not reach byte 0 is not a
    /// transfer: it reads zero and pushes nothing.
    pub fn carriesData(self: Access) bool {
        return self.names(0);
    }

    /// The byte a store hands the data port.
    pub fn dataByte(value: u32) u8 {
        return @truncate(value);
    }
};
