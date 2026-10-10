//! The steps `usbip list` and `usbip attach` take, over any Io reader and
//! writer (RA8EMU-75 slice 5b): list the exports, import one, then run URBs
//! on it. The end-to-end check drives these against `--usbip PORT`; the
//! tests drive them against the server's own replies.
const std = @import("std");
const wire = @import("wire.zig");
const client = @import("client.zig");

pub const Error = error{ Refused, Unexpected, Overflow };

/// Ask for the device list and return the first export, or null when there
/// is none. The returned busid points into `record`.
pub fn first(reader: *std.Io.Reader, writer: *std.Io.Writer, record: *[wire.device_len]u8) !?client.Listed {
    var request: [wire.op_header_len]u8 = undefined;
    client.devlist(&request);
    try writer.writeAll(&request);
    try writer.flush();
    try expectReply(reader, wire.op.rep_devlist);
    const count = try reader.takeInt(u32, .big);
    if (count == 0) return null;
    try readRecord(reader, record);
    var scratch: [wire.device_len]u8 = undefined;
    for (1..count) |_| try readRecord(reader, &scratch);
    return try client.Listed.decode(record);
}

/// Import `busid`; the stream carries URBs once this returns.
pub fn import(reader: *std.Io.Reader, writer: *std.Io.Writer, busid: []const u8, record: *[wire.device_len]u8) !client.Listed {
    var request: [client.import_len]u8 = undefined;
    try client.importRequest(&request, busid);
    try writer.writeAll(&request);
    try writer.flush();
    try expectReply(reader, wire.op.rep_import);
    try reader.readSliceAll(record);
    return client.Listed.decode(record);
}

/// Send one URB with its OUT data and read its reply, IN data into `in_buf`.
pub fn transfer(reader: *std.Io.Reader, writer: *std.Io.Writer, urb: client.Urb, out_data: []const u8, in_buf: []u8) !client.Returned {
    var header: [wire.basic_len]u8 = undefined;
    client.submit(&header, urb);
    try writer.writeAll(&header);
    if (urb.direction == .out) try writer.writeAll(out_data[0..urb.length]);
    try writer.flush();
    try reader.readSliceAll(&header);
    const back = try client.Returned.decode(&header);
    if (back.seqnum != urb.seqnum) return error.Unexpected;
    if (urb.direction == .in and back.actual > 0) {
        if (back.actual > in_buf.len) return error.Overflow;
        try reader.readSliceAll(in_buf[0..back.actual]);
    }
    return back;
}

fn expectReply(reader: *std.Io.Reader, code: u16) !void {
    var header: [wire.op_header_len]u8 = undefined;
    try reader.readSliceAll(&header);
    const reply = try wire.OpHeader.decode(&header);
    if (reply.code != code) return error.Unexpected;
    if (reply.status != 0) return error.Refused;
}

/// One device record plus the interface entries its last byte counts.
fn readRecord(reader: *std.Io.Reader, record: *[wire.device_len]u8) !void {
    try reader.readSliceAll(record);
    try reader.discardAll(@as(usize, record[wire.device_len - 1]) * wire.interface_len);
}
