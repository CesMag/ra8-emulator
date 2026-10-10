//! The DRW display list: the same register writes, fetched from memory
//! instead of taken from the CPU (HUM Ch 62.6, TES D/AVE list format).
//!
//! Split out of drw.zig because it is a different thing: that file is a
//! register window and a rasterizer, this is a reader walking words in
//! memory and saying which register each one is for. It decides nothing
//! about pixels; drw.zig executes what comes back exactly as it executes a
//! CPU write, so an ORIGIN entry in a list triggers a render the same way.
//!
//! The encoding is the one the ra8_drw builder emits and the bench confirmed
//! for issue #247: a one-index tag (bit 15 set, the register index in the
//! low byte) followed by one value word, and end-of-list words whose low
//! byte is 0xFF with the argument in byte 1. Multi-index packing was never
//! observed, so the reader stops on it rather than guessing.
const Guest = @import("../../core/cpu/memory/guest.zig").Guest;

pub const encoding = struct {
    pub const index_mask: u32 = 0xFF;
    pub const one_index: u32 = 0x0000_8000;
    pub const end_of_list: u32 = 0xFF;
    pub const argument_shift: u5 = 8;
    /// Wait for the pipeline and cache, then keep reading.
    pub const argument_wait: u32 = 2;
    /// A DLISTSTART entry inside a list is a jump, which is where this
    /// reader stops.
    pub const dliststart_index: u32 = 50;
    pub const bytes_per_word: u32 = 4;
    /// A bound on the fetch, so a corrupt list cannot spin the run.
    pub const max_words: u32 = 4096;
};

/// Why the reader stopped, as against handing back another entry.
pub const Stop = enum {
    /// An end-of-list word, or a jump this reader does not follow.
    ended,
    /// A word the memory would not give up.
    fault,
    /// Multi-index packing, or a list longer than the fetch bound: both are
    /// encodings this model will not invent the pixels for.
    unmodelled,
};

/// One register write the list asked for: the register's index, which is its
/// byte offset over four, and the value.
pub const Entry = struct {
    index: u32,
    value: u32,
};

/// A cursor over one list.
pub const Reader = struct {
    memory: Guest,
    cursor: u32,
    fetched: u32 = 0,

    pub fn init(memory: Guest, at: u32) Reader {
        return .{ .memory = memory, .cursor = at };
    }

    /// The next register write, or why there is not one.
    pub fn next(self: *Reader) union(enum) { entry: Entry, stop: Stop } {
        if (self.fetched >= encoding.max_words) return .{ .stop = .unmodelled };
        self.fetched += 1;
        const tag = self.word() orelse return .{ .stop = .fault };
        if (tag & encoding.one_index != 0) {
            const index = tag & encoding.index_mask;
            if (index == encoding.dliststart_index) return .{ .stop = .ended };
            const value = self.word() orelse return .{ .stop = .fault };
            return .{ .entry = .{ .index = index, .value = value } };
        }
        if (tag & encoding.index_mask == encoding.end_of_list) {
            const argument = tag >> encoding.argument_shift & encoding.index_mask;
            if (argument == encoding.argument_wait) return self.next();
            return .{ .stop = .ended };
        }
        return .{ .stop = .unmodelled };
    }

    fn word(self: *Reader) ?u32 {
        const value = self.memory.readWord(self.cursor) catch return null;
        self.cursor +%= encoding.bytes_per_word;
        return value;
    }
};
