//! README verdicts for examples that ship no bench conf (RA8EMU-400).
//!
//! An image with no foo.hil.conf beside it has no HIL_EXPECT to judge its
//! console by, and its last line rarely says OK or PASS, so its row stays
//! unknown however well it ran. Where the example's README and main.c name
//! the line a good run prints, and the line a bad run prints, this table
//! carries both and the row is judged on its last console line.
//!
//! Only lines the firmware source prints verbatim go here. An image whose
//! README names no such line stays unknown until someone reads it.
//!
//! lin_commander_hil drives the LIN commander transmit path only: its README
//! says a real exchange needs a transceiver and a responder, so a sent frame
//! is the whole of what it can show. main.c prints "frame sent" after each
//! frame and "LIN TX error" when the driver refuses one.
//!
//! usb_host_file_ops: main.c prints "ALL FILE OPS PASSED" after the ninth
//! step, and the step runner prints "fileops: FAIL" when one goes wrong.
const std = @import("std");
const hil_conf = @import("hil_conf");

pub const Expect = struct {
    image: []const u8,
    /// The line, or part of it, a good run ends on.
    pass: []const u8,
    /// The line, or part of it, a bad run ends on.
    fail: []const u8,
};

const table = [_]Expect{
    .{
        .image = "lin_commander_hil.elf",
        .pass = "lin_commander_hil: frame sent",
        .fail = "lin_commander_hil: LIN TX error",
    },
    .{
        .image = "usb_host_file_ops.elf",
        .pass = "ra8d2 fileops: ALL FILE OPS PASSED",
        .fail = "ra8d2 fileops: FAIL",
    },
};

/// The README verdict for an image, matched on its whole file name.
pub fn find(image: []const u8) ?Expect {
    for (table) |entry| {
        if (std.mem.eql(u8, entry.image, image)) return entry;
    }
    return null;
}

/// Judges a row's last console line. A fail line wins over a pass line;
/// neither, or no console at all, leaves the row to the usual rules.
pub fn judge(expect: Expect, console: ?[]const u8) ?hil_conf.Judgement {
    const line = console orelse return null;
    if (std.mem.indexOf(u8, line, expect.fail) != null) return .fail;
    if (std.mem.indexOf(u8, line, expect.pass) != null) return .pass;
    return null;
}
