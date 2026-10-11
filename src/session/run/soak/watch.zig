//! Firmware-side corruption a soak watches (RA8EMU-619).
//!
//! A `--run-for` soak keeps a short list of words the firmware should never
//! change: a ThreadX thread's stack-canary fill, a heap guard word. Each
//! boundary reads them once, beside the latched-fault check, and the first
//! word found changed is the soak's event. An empty list reads nothing, so a
//! run with nothing to watch costs nothing. An unreadable word is not a
//! change: the run report has the same view of a word it cannot read.
const Kind = @import("soak.zig").Kind;

/// Words one soak can watch; plenty for a firmware's threads and heaps.
pub const max_words = 64;

/// One watched word and the value it should keep.
pub const Word = struct {
    address: u32,
    expected: u32,
    kind: Kind,
};

/// The first watched word found changed: what it was and where.
pub const Changed = struct {
    kind: Kind,
    address: u32,
};

pub const Watch = struct {
    words: [max_words]Word = undefined,
    len: usize = 0,

    /// Watch `word` from now on. A full list refuses rather than drops one.
    pub fn add(self: *Watch, word: Word) error{Full}!void {
        if (self.len == max_words) return error.Full;
        self.words[self.len] = word;
        self.len += 1;
    }

    /// The words being watched.
    pub fn list(self: *const Watch) []const Word {
        return self.words[0..self.len];
    }

    /// Stop watching every word of `kind`, keeping the rest in order.
    pub fn drop(self: *Watch, kind: Kind) void {
        var kept: usize = 0;
        for (self.list()) |word| {
            if (word.kind == kind) continue;
            self.words[kept] = word;
            kept += 1;
        }
        self.len = kept;
    }

    /// The first word that no longer holds its value, or null when every
    /// readable word does. `memory` is anything with `readWord(address) !u32`.
    pub fn changed(self: *const Watch, memory: anytype) ?Changed {
        for (self.list()) |word| {
            const now = memory.readWord(word.address) catch continue;
            if (now != word.expected) return .{ .kind = word.kind, .address = word.address };
        }
        return null;
    }
};
