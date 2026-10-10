//! Covers src/chip/periph/npu/npu_cmd.zig: what counts as a program this model can
//! run, and the refusals that keep it from running one it cannot.
const std = @import("std");
const ra8 = @import("ra8");
const cmd = ra8.chip.periph.npu_cmd;

fn stream(op: u32, source: u32, destination: u32, count: u32, addend: u32) [cmd.header.words]u32 {
    return .{ cmd.header.magic | op, source, destination, count, addend };
}

test "a copy stream decodes into the job it describes" {
    const program = try cmd.decode(cmd.header.bytes, stream(1, 2, 3, 64, 0));
    try std.testing.expectEqual(cmd.Op.copy, program.op);
    try std.testing.expectEqual(@as(u32, 2), program.source);
    try std.testing.expectEqual(@as(u32, 3), program.destination);
    try std.testing.expectEqual(@as(u32, 64), program.count);
}

test "an add-constant stream keeps its constant" {
    const program = try cmd.decode(cmd.header.bytes, stream(2, 0, 1, 4, 7));
    try std.testing.expectEqual(cmd.Op.add_constant, program.op);
    try std.testing.expectEqual(@as(u32, 7), program.addend);
}

test "an opcode this model does not implement is refused, not run as a copy" {
    try std.testing.expectError(
        cmd.Reject.UnknownOpcode,
        cmd.decode(cmd.header.bytes, stream(7, 0, 1, 16, 0)),
    );
}

test "a stream without our marker is somebody else's program" {
    const vela: [cmd.header.words]u32 = .{ 0x0000_0001, 0, 1, 16, 0 };
    try std.testing.expectError(cmd.Reject.NotOurs, cmd.decode(cmd.header.bytes, vela));
}

test "a stream shorter than the header carries no program" {
    try std.testing.expectError(
        cmd.Reject.ShortStream,
        cmd.decode(cmd.header.bytes - 1, stream(1, 0, 1, 16, 0)),
    );
}

test "a region index with no base pointer behind it is refused" {
    try std.testing.expectError(
        cmd.Reject.BadRegion,
        cmd.decode(cmd.header.bytes, stream(1, cmd.limits.regions, 1, 16, 0)),
    );
    try std.testing.expectError(
        cmd.Reject.BadRegion,
        cmd.decode(cmd.header.bytes, stream(1, 0, cmd.limits.regions, 16, 0)),
    );
}

test "a job has to move something, and no more than the loop is bounded to" {
    try std.testing.expectError(
        cmd.Reject.BadCount,
        cmd.decode(cmd.header.bytes, stream(1, 0, 1, 0, 0)),
    );
    try std.testing.expectError(
        cmd.Reject.BadCount,
        cmd.decode(cmd.header.bytes, stream(1, 0, 1, cmd.limits.max_bytes + 1, 0)),
    );
}

test "the largest job the model takes is still a job" {
    const program = try cmd.decode(cmd.header.bytes, stream(1, 0, 1, cmd.limits.max_bytes, 0));
    try std.testing.expectEqual(cmd.limits.max_bytes, program.count);
}

test "a copy leaves a byte alone and add-constant wraps it at eight bits" {
    const copy = try cmd.decode(cmd.header.bytes, stream(1, 0, 1, 4, 9));
    try std.testing.expectEqual(@as(u8, 0x41), copy.transform(0x41));
    const add = try cmd.decode(cmd.header.bytes, stream(2, 0, 1, 4, 0x10));
    try std.testing.expectEqual(@as(u8, 0x0F), add.transform(0xFF));
}

test "a job whose source and destination are the same region is in place" {
    const same = try cmd.decode(cmd.header.bytes, stream(1, 2, 2, 8, 0));
    try std.testing.expect(same.inPlace());
    const across = try cmd.decode(cmd.header.bytes, stream(1, 2, 3, 8, 0));
    try std.testing.expect(!across.inPlace());
}

test "the checkword folds the bytes it is given, in order" {
    var one = cmd.Check{};
    one.fold("abc");
    var two = cmd.Check{};
    two.fold("cba");
    try std.testing.expect(one.value != two.value);
    try std.testing.expect(one.value != cmd.Check.offset_basis);
}

test "encode lays down a header decode reads back" {
    const program = cmd.Command{ .op = .add_constant, .source = 1, .destination = 5, .count = 32, .addend = 3 };
    const round = try cmd.decode(cmd.header.bytes, cmd.encode(program));
    try std.testing.expectEqual(program, round);
}

test "the two opcodes say their own names" {
    try std.testing.expectEqualStrings("copy", cmd.Op.copy.label());
    try std.testing.expectEqualStrings("add-const", cmd.Op.add_constant.label());
}
