//! What to do about a card the formatter refused.
//!
//! The error name alone sends a reader to the source to learn that a FAT32
//! volume needs 65525 clusters before it is allowed to call itself one, and
//! that at 512 bytes a cluster that is more card than the 32 MB this model
//! comes up with. So the refusal names a size that would have worked, and
//! the other width when that fits the card in hand.
//!
//! The sizes are computed by the same solver that did the refusing, so they
//! cannot drift away from it, and they are whole megabytes, which is both
//! what the command line takes and a whole number of the 512 KiB units a
//! CSD counts in, so a size named here is always one the card can be
//! resized to.
const std = @import("std");
const sd_format = @import("format.zig");

/// Print the remedy for a refusal the geometry made. A refusal that is not
/// about size (a bad label, a card that would not take the writes) says
/// nothing here: the error name is already the whole story.
pub fn printRemedy(kind: sd_format.Kind, err: anyerror) void {
    switch (err) {
        error.TooFewClusters => tooSmall(kind),
        error.TooManyClusters => tooLarge(kind),
        else => {},
    }
}

fn tooSmall(kind: sd_format.Kind) void {
    const mib = sd_format.smallestCardMib(kind) orelse return;
    std.debug.print(
        "         this card is too small for {s}: try --sd-size {d}\n",
        .{ kind.text(), mib },
    );
    if (kind == .fat32) {
        std.debug.print("         or --sd-new fat16, which fits this card\n", .{});
    }
}

fn tooLarge(kind: sd_format.Kind) void {
    const mib = sd_format.largestCardMib(kind) orelse return;
    std.debug.print(
        "         this card is too large for {s}: try --sd-size {d}\n",
        .{ kind.text(), mib },
    );
    if (kind == .fat16) {
        std.debug.print("         or --sd-new fat32, which fits this card\n", .{});
    }
}
