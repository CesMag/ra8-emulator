//! The board's NPU in a snapshot (RA8EMU-685): registers, the STATUS this
//! model computes, job and fault counters, the last op, the Vela counters and
//! the pending interrupt, as one `npu` section.
//!
//! Not saved, because it is wiring: `memory` (the guest memory handle the
//! board attaches). A load keeps the target board's own.
const std = @import("std");
const file = @import("ra8_snapshot").file;
const fields = @import("ra8_snapshot").fields;

pub const Error = file.Error || fields.Error || error{Missing};

const wiring = .{"memory"};

pub fn save(board: anytype, writer: anytype) !void {
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try fields.writeExcept(&counter.writer, board.npu, wiring);
    try file.writeSectionHeader(writer, .npu, counter.fullCount());
    try fields.writeExcept(writer, board.npu, wiring);
}

/// All or nothing: the NPU changes only once the whole section read cleanly.
pub fn load(board: anytype, bytes: []const u8) Error!void {
    const section = try file.Reader.find(bytes, .npu) orelse return Error.Missing;
    var cursor: fields.Cursor = .{ .bytes = section.payload };
    var copy = board.npu;
    try fields.readOver(&cursor, &copy, wiring);
    if (!cursor.done()) return Error.BadValue;
    board.npu = copy;
}
