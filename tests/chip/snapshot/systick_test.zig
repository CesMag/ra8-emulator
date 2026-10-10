//! RA8EMU-694: the run's two SysTick time bases saved mid-run and loaded into
//! fresh ones match byte for byte, keep the target's own words and chunk, and
//! a short section changes nothing.
const std = @import("std");
const ra8 = @import("ra8");
const clocks = ra8.chip.periph.clocks;
const file = ra8.snapshot.file;
const section = ra8.chip.snapshot.systick;

fn running() [2]clocks.Clocks {
    var secure: clocks.Clocks = .{};
    secure.elapsed = 1 << 34;
    secure.cycles = 12_345;
    secure.ticks = 77;
    secure.pends = 70;
    secure.collapsed = 3;
    secure.rearms = 2;
    secure.restart = true;
    var non_secure: clocks.Clocks = .{ .words = clocks.Words.non_secure };
    non_secure.elapsed = 9_000;
    non_secure.ticks = 4;
    return .{ secure, non_secure };
}

fn saved(bases: *const [2]clocks.Clocks, list: *std.Io.Writer.Allocating) !void {
    try file.writeHeader(&list.writer);
    try section.save(.{ &bases[0], &bases[1] }, &list.writer);
}

test "both time bases round-trip byte for byte" {
    const bases = running();
    var first = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer first.deinit();
    try saved(&bases, &first);

    var fresh: [2]clocks.Clocks = .{ .{}, .{ .words = clocks.Words.non_secure } };
    try section.load(.{ &fresh[0], &fresh[1] }, first.written());
    var second = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer second.deinit();
    try saved(&fresh, &second);
    try std.testing.expectEqualSlices(u8, first.written(), second.written());
    try std.testing.expectEqual(@as(u64, 1 << 34), fresh[0].elapsed);
    try std.testing.expect(fresh[0].restart);
    try std.testing.expectEqual(@as(u64, 4), fresh[1].ticks);
}

test "the target keeps its own words and chunk" {
    const bases = running();
    var bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer bytes.deinit();
    try saved(&bases, &bytes);

    var target: [2]clocks.Clocks = .{ .{ .per_chunk = 8 }, .{ .words = clocks.Words.non_secure, .per_chunk = 8 } };
    try section.load(.{ &target[0], &target[1] }, bytes.written());
    try std.testing.expectEqual(@as(u32, 8), target[0].per_chunk);
    try std.testing.expectEqual(clocks.Words.non_secure.csr, target[1].words.csr);
    try std.testing.expectEqual(@as(u64, 77), target[0].ticks);
}

test "a short section leaves both bases untouched" {
    const bases = running();
    var bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer bytes.deinit();
    try file.writeHeader(&bytes.writer);
    var whole = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer whole.deinit();
    try section.save(.{ &bases[0], &bases[1] }, &whole.writer);
    const header_len = whole.written().len - sectionBody(&bases);
    try file.writeSectionHeader(&bytes.writer, .systick, 9);
    try bytes.writer.writeAll(whole.written()[header_len .. header_len + 9]);

    var target: [2]clocks.Clocks = .{ .{}, .{} };
    try std.testing.expectError(error.Truncated, section.load(.{ &target[0], &target[1] }, bytes.written()));
    try std.testing.expectEqual(@as(u64, 0), target[0].elapsed);
    try std.testing.expectEqual(@as(u64, 0), target[1].ticks);
}

fn sectionBody(bases: *const [2]clocks.Clocks) usize {
    var counter: std.Io.Writer.Discarding = .init(&.{});
    for (bases) |base| ra8.snapshot.fields.writeExcept(&counter.writer, base, .{ "per_chunk", "words" }) catch unreachable;
    return @intCast(counter.fullCount());
}
