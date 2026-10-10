//! The board's USB side in a snapshot (RA8EMU-682): the HS host controller,
//! the FS device on the other jack and the scripted host on it, then the
//! MSC target, as one `usb` section.
//!
//! Not saved, because it is wiring: the cable between the jacks (laid by
//! `loopBack`; it holds a device pointer), the usbip bridge hook, the HS
//! transfer's far-end pointer and the echo device's pointer to the stick. A
//! load keeps the target's. The MSC target saves its own half
//! (components/usb_stick/snapshot.zig, RA8EMU-1104), after the rest.
const std = @import("std");
const file = @import("ra8_snapshot").file;
const fields = @import("ra8_snapshot").fields;
const stick_half = @import("ra8_components").stick_snapshot;

pub const Error = file.Error || fields.Error || error{Missing};

const skip: []const []const u8 = &.{ "host.xfer.far", "echo.storage", "cable", "bridge", "stick" };

pub fn save(board: anytype, writer: anytype) !void {
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try body(&counter.writer, board);
    try file.writeSectionHeader(writer, .usb, counter.fullCount());
    try body(writer, board);
}

fn body(writer: anytype, board: anytype) !void {
    try fields.writeExcept(writer, board.usb, skip);
    try stick_half.write(writer, &board.usb.stick);
}

/// All or nothing: the section is read over a copy, both cursors are
/// checked against the target's buffers, and only then does the board change.
pub fn load(board: anytype, bytes: []const u8) Error!void {
    const section = try file.Reader.find(bytes, .usb) orelse return Error.Missing;
    var cursor: fields.Cursor = .{ .bytes = section.payload };
    var usb = board.usb;
    try fields.readOver(&cursor, &usb, skip);
    const target = try stick_half.read(&cursor, &board.usb.stick);
    if (!cursor.done() or !target.fits()) return Error.BadValue;
    board.usb = usb;
    target.install(&board.usb.stick);
}
