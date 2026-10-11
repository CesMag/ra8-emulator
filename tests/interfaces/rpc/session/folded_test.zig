//! Tests for src/interfaces/rpc/session/folded.zig (RA8EMU-833) on a served
//! image sampled with sampleStacks: folded answers the rows the same fold
//! --profile-folded uses, split cleanly by window, and refuses what takes
//! no sample. The fixture is the real DFU bootloader (tests/fixtures/dfu).
const std = @import("std");
const ra8 = @import("ra8");

const setup = ra8.rpc.served_setup;
const folded = ra8.rpc.session.folded;
const proto = ra8.rpc.session.rpc;
const app_codes = ra8.rpc.session.server.app_codes;
const stack_samples = ra8.session.stack.samples;
const stack_profile = ra8.session.stack.profile;

const image = "tests/fixtures/dfu/dfu_bootloader.elf";

fn ask(context: anytype, args: proto.FoldedAsk) ![]const u8 {
    return switch (folded.folded(context, args)) {
        .ok => |rows| rows.text,
        .err => |code| if (@backingInt(code) == app_codes.too_long) error.TooLong else error.Refused,
    };
}

fn sampled(opened: *setup.Served) !void {
    try opened.open(std.testing.allocator, std.testing.io, image);
    errdefer opened.deinit();
    try opened.sampleStacks(500);
    const session = opened.owner.session();
    session.live.budget = 300_000;
    _ = try session.run(.cpu0, .cont);
}

fn total(rows: []const u8) !u64 {
    var sum: u64 = 0;
    var lines = std.mem.tokenizeScalar(u8, rows, '\n');
    while (lines.next()) |line| sum += try std.fmt.parseInt(u64, line[std.mem.lastIndexOfScalar(u8, line, ' ').? + 1 ..], 10);
    return sum;
}

test "folded is the --profile-folded fold of CPU0's samples" {
    var opened: setup.Served = undefined;
    try sampled(&opened);
    defer opened.deinit();
    const store = &opened.stacks.?.store;
    const owned = opened.owner.image();
    var expected: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer expected.deinit();
    var scratch: [stack_samples.limits.samples]usize = undefined;
    try stack_samples.fold(store, .{ .core = 0 }, stack_profile.names(&owned), &expected.writer, &scratch);
    const rows = try ask(&opened.context, .{ .core = .cpu0 });
    try std.testing.expectEqualStrings(expected.written(), rows);
    try std.testing.expectEqual(@as(u64, store.count), try total(rows));
}

test "two halves of a window count what the whole window does" {
    var opened: setup.Served = undefined;
    try sampled(&opened);
    defer opened.deinit();
    const store = &opened.stacks.?.store;
    const first = store.at(0).at_ns;
    const last = store.at(store.count - 1).at_ns + 1;
    const middle = first + (last - first) / 2;
    const whole = try total(try ask(&opened.context, .{ .core = .cpu0, .from_ns = first, .to_ns = last }));
    const early = try total(try ask(&opened.context, .{ .core = .cpu0, .from_ns = first, .to_ns = middle }));
    const late = try total(try ask(&opened.context, .{ .core = .cpu0, .from_ns = middle, .to_ns = last }));
    try std.testing.expectEqual(whole, early + late);
    try std.testing.expect(early > 0 and late > 0);
}

test "an empty window, an unknown thread, CPU1 and no sampling are refused" {
    var opened: setup.Served = undefined;
    try sampled(&opened);
    defer opened.deinit();
    try std.testing.expectError(error.Refused, ask(&opened.context, .{ .core = .cpu0, .from_ns = 10, .to_ns = 10 }));
    try std.testing.expectError(error.Refused, ask(&opened.context, .{ .core = .cpu0, .from_ns = 0xFFFF_FFFF_FFFF_0000 }));
    try std.testing.expectError(error.Refused, ask(&opened.context, .{ .core = .cpu0, .thread = 0x2000_0000 }));
    try std.testing.expectError(error.Refused, ask(&opened.context, .{ .core = .cpu1 }));
    const hook = opened.context.folding;
    opened.context.folding = null;
    defer opened.context.folding = hook;
    try std.testing.expectError(error.Refused, ask(&opened.context, .{ .core = .cpu0 }));
}

test "rows longer than the scratch are too long" {
    var opened: setup.Served = undefined;
    try sampled(&opened);
    defer opened.deinit();
    const scratch = opened.context.scratch;
    opened.context.scratch = scratch[0..8];
    defer opened.context.scratch = scratch;
    try std.testing.expectError(error.TooLong, ask(&opened.context, .{ .core = .cpu0 }));
}
