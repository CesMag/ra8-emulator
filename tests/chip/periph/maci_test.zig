//! Covers src/chip/periph/maci.zig: the command stream and what counts as a
//! whole command.
const std = @import("std");
const ra8 = @import("ra8");

const maci = ra8.chip.periph.maci;

fn program(stream: *maci.Sequencer, halfwords: []const u16) maci.Step {
    _ = stream.byteWritten(maci.opcode.program);
    _ = stream.byteWritten(@intCast(halfwords.len));
    for (halfwords) |value| stream.halfwordWritten(value);
    return stream.byteWritten(maci.opcode.final);
}

test "a fresh stream is idle and carries nothing" {
    var stream = maci.Sequencer{};
    try std.testing.expectEqual(maci.State.idle, stream.state);
    try std.testing.expectEqual(@as(usize, 0), stream.bytes().len);
    try std.testing.expect(!stream.complete());
}

test "a halfword outside a stream is dropped" {
    var stream = maci.Sequencer{};
    stream.halfwordWritten(0xBEEF);
    try std.testing.expectEqual(@as(usize, 0), stream.bytes().len);
}

test "the opener and the count open the stream" {
    var stream = maci.Sequencer{};
    try std.testing.expectEqual(maci.Step.none, stream.byteWritten(maci.opcode.program));
    try std.testing.expectEqual(maci.State.opened, stream.state);
    try std.testing.expectEqual(maci.Step.none, stream.byteWritten(4));
    try std.testing.expectEqual(maci.State.collecting, stream.state);
    try std.testing.expectEqual(@as(usize, 4), stream.declared);
}

test "the count byte is a count, not the literal dev insists on" {
    var stream = maci.Sequencer{};
    const halfwords = [_]u16{ 0x1234, 0x5678 };
    try std.testing.expectEqual(maci.Step.commit, program(&stream, &halfwords));
    try std.testing.expect(stream.complete());
}

test "halfwords are collected little-endian, in order" {
    var stream = maci.Sequencer{};
    const halfwords = [_]u16{ 0x1234, 0xABCD };
    _ = program(&stream, &halfwords);
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0xCD, 0xAB }, stream.bytes());
}

test "the config-set opener is remembered as its own kind" {
    var stream = maci.Sequencer{};
    _ = stream.byteWritten(maci.opcode.config_set);
    try std.testing.expectEqual(maci.Kind.config_set, stream.kind);
}

test "a short command is not complete" {
    var stream = maci.Sequencer{};
    _ = stream.byteWritten(maci.opcode.program);
    _ = stream.byteWritten(8);
    stream.halfwordWritten(0x1111);
    try std.testing.expectEqual(maci.Step.commit, stream.byteWritten(maci.opcode.final));
    try std.testing.expect(!stream.complete());
}

test "a long command overflows rather than growing" {
    var stream = maci.Sequencer{};
    _ = stream.byteWritten(maci.opcode.program);
    _ = stream.byteWritten(16);
    for (0..16) |_| stream.halfwordWritten(0x2222);
    try std.testing.expectEqual(@as(usize, maci.max_payload), stream.bytes().len);
    try std.testing.expect(stream.overflowed);
    try std.testing.expect(!stream.complete());
}

test "a stray byte mid-stream abandons the command" {
    var stream = maci.Sequencer{};
    _ = stream.byteWritten(maci.opcode.program);
    _ = stream.byteWritten(2);
    stream.halfwordWritten(0x3333);
    try std.testing.expectEqual(maci.Step.abandoned, stream.byteWritten(0x55));
    try std.testing.expectEqual(maci.State.idle, stream.state);
    try std.testing.expectEqual(@as(usize, 0), stream.bytes().len);
}

test "a declaration of nothing is never complete" {
    var stream = maci.Sequencer{};
    _ = stream.byteWritten(maci.opcode.program);
    _ = stream.byteWritten(0);
    try std.testing.expectEqual(maci.Step.commit, stream.byteWritten(maci.opcode.final));
    try std.testing.expect(!stream.complete());
}

test "an opener mid-stream abandons the command rather than restarting it" {
    var stream = maci.Sequencer{};
    _ = stream.byteWritten(maci.opcode.program);
    _ = stream.byteWritten(2);
    stream.halfwordWritten(0x4444);
    // Only the trailer runs a command: anything else mid-stream drops it,
    // where dev takes an opener here and silently starts another.
    try std.testing.expectEqual(maci.Step.abandoned, stream.byteWritten(maci.opcode.program));
    try std.testing.expectEqual(maci.State.idle, stream.state);
    try std.testing.expectEqual(@as(usize, 0), stream.bytes().len);
    // The next opener opens as usual.
    try std.testing.expectEqual(maci.Step.none, stream.byteWritten(maci.opcode.program));
    try std.testing.expectEqual(maci.State.opened, stream.state);
}

test "reset puts the stream back to idle" {
    var stream = maci.Sequencer{};
    _ = program(&stream, &[_]u16{0x5555});
    stream.reset();
    try std.testing.expectEqual(maci.State.idle, stream.state);
    try std.testing.expectEqual(@as(usize, 0), stream.declared);
}
