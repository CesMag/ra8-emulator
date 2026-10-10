//! The core registers a run prints when asked, and how the line reads.
//!
//! `--break-sym` stops on a function's own first instruction, before its
//! prologue has moved anything. That is the one moment the argument
//! registers still hold the arguments, so the question a wall raises
//! ("which of these guards refused, and with what lba") is answerable by
//! reading them. After the prologue they are scratch and say nothing.
//!
//! The register set here is the caller-saved one the engine already
//! exposes, which is exactly the set AAPCS passes arguments in, plus the
//! three that say where execution is. r4 upward are callee-saved and are
//! not arguments, so their absence costs nothing at a call boundary.
//!
//! A 64-bit argument rides an even-odd register pair and pushes the rest
//! of the arguments onto the stack, so the words at the stack pointer are
//! printed too: without them a function like
//! `read_block(ctx, uint64_t lba, count, buf)` shows its lba and hides its
//! count.
const std = @import("std");
const Cortex = @import("ra8_chip").core.cpu.cortex.Cortex;

pub const limits = struct {
    /// How many registers share one printed line.
    pub const per_line: usize = 4;
    /// How many words from the stack pointer are printed. Four covers the
    /// arguments that did not fit in registers for every call in this
    /// firmware.
    pub const stack_words: usize = 4;
};

/// A register under the name the ABI calls it.
pub const Named = struct {
    name: []const u8,
    which: Cortex,
};

/// What a dump prints, in the order it prints them. The argument
/// registers lead because at a break they are still the arguments.
pub const dumped = [_]Named{
    .{ .name = "r0", .which = .r0 },
    .{ .name = "r1", .which = .r1 },
    .{ .name = "r2", .which = .r2 },
    .{ .name = "r3", .which = .r3 },
    .{ .name = "r12", .which = .r12 },
    .{ .name = "sp", .which = .sp },
    .{ .name = "lr", .which = .lr },
    .{ .name = "pc", .which = .pc },
};

/// Does a line end after the register at this index?
///
/// The last register ends its line whether or not it fills one, so a dump
/// never leaves a row hanging without a newline.
pub fn endsLine(index: usize) bool {
    if (index + 1 == dumped.len) return true;
    return (index + 1) % limits.per_line == 0;
}

/// The address of the nth word above the stack pointer.
pub fn stackWord(sp: u32, index: usize) u32 {
    return sp +% @as(u32, @intCast(index * @sizeOf(u32)));
}
