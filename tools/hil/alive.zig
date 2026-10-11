//! The bench's alive check, as far as a console run can see it (RA8EMU-400).
//!
//! ra8-firmware's scripts/hil/check_alive.sh passes an alive example when its PC keeps
//! advancing in code and its console carries none of the words in NEG_RE.
//! A run that ends clean on its budget kept executing, so the table needs
//! only the console half: `refused` is NEG_RE, matched on word boundaries.
const std = @import("std");

/// check_alive.sh's NEG_RE alternatives, the stack-overflow spellings
/// written out.
pub const negatives = [_][]const u8{
    "FAIL",           "FAILED",         "panic",          "NAK",           "ERROR",
    "HardFault",      "hardfault",      "MemFault",       "BusFault",      "UsageFault",
    "stack overflow", "stack_overflow", "stack-overflow", "stackoverflow",
};

/// Whether `text` carries any negative as a whole word.
pub fn refused(text: []const u8) bool {
    for (negatives) |word| {
        if (wordAt(text, word)) return true;
    }
    return false;
}

fn wordAt(text: []const u8, word: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, word)) |at| {
        const end = at + word.len;
        const open = at == 0 or !isWord(text[at - 1]);
        const close = end == text.len or !isWord(text[end]);
        if (open and close) return true;
        from = at + 1;
    }
    return false;
}

fn isWord(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}
