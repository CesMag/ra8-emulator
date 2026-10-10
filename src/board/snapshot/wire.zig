//! The board's I2C wire in a snapshot (RA8EMU-666): the RIIC channels, the
//! I3C touch line and the parts on both, as one `wire` section.
//!
//! Not saved, because it is wiring: the device registries (pointers to the
//! parts), each RIIC channel's rx clock (a pointer to the time base) and
//! `click` (which parts the board was built with). A registry's `held_low`
//! is the bus's own state, so it is.
const std = @import("std");
const file = @import("ra8_snapshot").file;
const fields = @import("ra8_snapshot").fields;

pub const Error = file.Error || fields.Error || error{Missing};

pub fn save(board: anytype, writer: anytype) !void {
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try body(&counter.writer, &board.wire);
    try file.writeSectionHeader(writer, .wire, counter.fullCount());
    try body(writer, &board.wire);
}

fn body(writer: anytype, wire: anytype) !void {
    for (wire.controller.channels) |channel| {
        try fields.writeExcept(writer, channel, .{"rx"});
        try fields.writeExcept(writer, channel.rx, .{"clock"});
    }
    try fields.write(writer, wire.controller.devices.held_low);
    try fields.writeExcept(writer, wire.touchline, .{"devices"});
    try fields.write(writer, wire.touchline.devices.held_low);
    try fields.write(writer, wire.expander);
    try fields.write(writer, wire.sensor);
    try fields.write(writer, wire.panel);
    try fields.write(writer, wire.imu);
    try fields.write(writer, wire.gauge);
}

/// All or nothing: the wire changes only once the whole section read
/// cleanly and every stage and queue index lands inside its buffer.
pub fn load(board: anytype, bytes: []const u8) Error!void {
    const section = try file.Reader.find(bytes, .wire) orelse return Error.Missing;
    var cursor: fields.Cursor = .{ .bytes = section.payload };
    var copy = board.wire;
    for (&copy.controller.channels) |*channel| {
        try fields.readOver(&cursor, channel, .{"rx"});
        try fields.readOver(&cursor, &channel.rx, .{"clock"});
    }
    copy.controller.devices.held_low = try fields.read(bool, &cursor);
    try fields.readOver(&cursor, &copy.touchline, .{"devices"});
    copy.touchline.devices.held_low = try fields.read(bool, &cursor);
    copy.expander = try fields.read(@TypeOf(copy.expander), &cursor);
    copy.sensor = try fields.read(@TypeOf(copy.sensor), &cursor);
    copy.panel = try fields.read(@TypeOf(copy.panel), &cursor);
    copy.imu = try fields.read(@TypeOf(copy.imu), &cursor);
    copy.gauge = try fields.read(@TypeOf(copy.gauge), &cursor);
    if (!cursor.done() or !fits(&copy)) return Error.BadValue;
    board.wire = copy;
}

fn fits(wire: anytype) bool {
    const line = wire.touchline;
    const panel = wire.panel;
    return line.staged_len <= line.staged.len and line.served <= line.staged_len and
        panel.queued_len <= panel.queued.len and panel.queued_pos <= panel.queued_len;
}
