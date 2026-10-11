//! Where in memory to look, as the command line spells it.
//!
//! `--dump-mem` takes a place rather than a bare address, because the thing
//! worth reading is rarely at an address known in advance. A filesystem
//! keeps the geometry it computes its sector numbers from inside a struct
//! it reached through a pointer: the struct's address changes run to run,
//! the offset into it does not. A place is therefore a base, an optional
//! single dereference, and an offset applied after it:
//!
//! ```
//! 0x22000058         the words at that address
//! g_eoh_err          the words at that global
//! @s_open+0x40       the words 0x40 past whatever s_open points at
//! *0x22000058        gdb's spelling of an address; the star is dropped
//! ```
//!
//! Parsing is all this file does. Resolving a name to an address and
//! reading a word behind it need the image and the core, and belong to
//! whoever holds them.
const std = @import("std");

pub const limits = struct {
    /// Words printed when the command line names no count.
    pub const default_words: u32 = 4;
    /// The most one dump will print. A struct worth reading this way is a
    /// mount or a descriptor, tens of words rather than a region.
    pub const max_words: u32 = 64;
    /// How many words share one printed line.
    pub const per_line: u32 = 4;
};

pub const Error = error{ EmptyPlace, BadOffset };

/// A place, parsed. `name` and `address` are alternatives: a place either
/// starts at a symbol or at a literal, never both.
pub const Place = struct {
    /// The symbol the base comes from, or null when the base is a literal.
    name: ?[]const u8 = null,
    /// The literal base, meaningful only when `name` is null.
    address: u32 = 0,
    /// Read a word at the base and take that as the base instead.
    deref: bool = false,
    /// Added after the dereference, never before: the offset is into the
    /// struct the pointer found, not into the pointer.
    offset: i32 = 0,

    /// The address this place names, once its base is known.
    ///
    /// Wrapping, so a negative offset off a low base says what the
    /// arithmetic says rather than trapping: a dump is a diagnostic, and a
    /// wrapped address simply will not read.
    pub fn apply(self: Place, base: u32) u32 {
        return @bitCast(@as(i32, @bitCast(base)) +% self.offset);
    }
};

/// Parse a place. A name is anything that is not a number, so an offset is
/// found first and the rest decided by whether it parses as one.
pub fn parse(text: []const u8) Error!Place {
    var found = Place{};
    var body = text;
    // gdb spells an address place `*EXPR` (`break *0x22000040`, `info line
    // *main`). The star only says "this is an address", so it is dropped.
    if (body.len > 0 and body[0] == '*') body = body[1..];
    if (body.len > 0 and body[0] == '@') {
        found.deref = true;
        body = body[1..];
    }
    if (body.len == 0) return error.EmptyPlace;

    // From the second byte on: a leading sign belongs to the base, and a
    // symbol name never carries one.
    if (std.mem.indexOfAny(u8, body[1..], "+-")) |at| {
        const cut = at + 1;
        found.offset = std.fmt.parseInt(i32, body[cut..], 0) catch return error.BadOffset;
        body = body[0..cut];
    }
    if (std.fmt.parseInt(u32, body, 0) catch null) |literal| {
        found.address = literal;
    } else {
        found.name = body;
    }
    return found;
}

/// How many words a dump prints, given what the command line asked for.
pub fn words(asked: ?u32) u32 {
    const want = asked orelse limits.default_words;
    return @min(want, limits.max_words);
}

/// Does the word at this index open a line?
pub fn startsLine(index: u32) bool {
    return index % limits.per_line == 0;
}

/// Does a line end after the word at this index?
///
/// The last word ends its line whether or not it fills one, so a dump
/// never leaves a row hanging without a newline.
pub fn endsLine(index: u32, total: u32) bool {
    if (index + 1 == total) return true;
    return (index + 1) % limits.per_line == 0;
}
