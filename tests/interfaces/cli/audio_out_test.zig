//! Tests for src/interfaces/cli/audio_out.zig: the flags, the container
//! widths, and SSIE0 driven through its registers into a written WAV.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const audio_out = cli_app.report.audio_out;
const ssie = ra8.chip.periph.ssie;

const allocator = std.testing.allocator;
const ch0 = ssie.channelAddress(0);

fn ssicr(dwl: u32, frm: u32, right: bool) u32 {
    const shape = (dwl << ssie.tap.dwl_shift) | (frm << ssie.tap.frm_shift);
    return shape | (if (right) ssie.tap.pdta else 0) | ssie.field.ten;
}

fn send(board: *ra8.board.board.Board, words: []const u32) void {
    for (words) |word| board.audio.write(ch0 + ssie.off_ssiftdr, 4, word);
}

const Output = struct {
    dir: std.testing.TmpDir,
    path: []u8,
    said: std.Io.Writer.Allocating,

    fn init() !Output {
        var dir = std.testing.tmpDir(.{});
        errdefer dir.cleanup();
        const root = try dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        defer allocator.free(root);
        const path = try std.fs.path.join(allocator, &.{ root, "out.wav" });
        return .{ .dir = dir, .path = path, .said = .init(allocator) };
    }

    fn deinit(self: *Output) void {
        self.said.deinit();
        allocator.free(self.path);
        self.dir.cleanup();
    }

    fn file(self: *Output) ![]u8 {
        return self.dir.dir.readFileAlloc(std.testing.io, "out.wav", allocator, .limited(1 << 20));
    }
};

test "the flags take a path and a rate, and refuse a zero rate" {
    var options: audio_out.Options = .{};
    const argv = [_][]const u8{ "--audio-out", "a.wav", "--audio-rate", "22050", "--audio-rate", "0" };
    var index: usize = 0;
    try std.testing.expect(try audio_out.parse(&options, &argv, &index));
    index += 1;
    try std.testing.expect(try audio_out.parse(&options, &argv, &index));
    try std.testing.expectEqualStrings("a.wav", options.path.?);
    try std.testing.expectEqual(@as(u32, 22050), options.rate);
    index += 1;
    try std.testing.expectError(error.BadAudioRate, audio_out.parse(&options, &argv, &index));
    var other: usize = 0;
    try std.testing.expect(!try audio_out.parse(&options, &.{"--frame-out"}, &other));
}

test "containers: 8 and 16 go to 16, 18 to 24 go to 24, 32 stays 32" {
    const cases = [_][2]u16{ .{ 8, 16 }, .{ 16, 16 }, .{ 18, 24 }, .{ 20, 24 }, .{ 22, 24 }, .{ 24, 24 }, .{ 32, 32 } };
    for (cases) |case| try std.testing.expectEqual(case[1], audio_out.container(@intCast(case[0])));
    const twenty = ssie.tap.shape(ssicr(3, 0, true)).?;
    try std.testing.expectEqual(@as(u32, 0xABCD1 << 4), audio_out.widen(twenty, 0x000A_BCD1));
}

test "a 16-bit I2S stream on SSIE0 is written as a stereo WAV at the asked rate" {
    var board = ra8.board.board.Board.init(allocator);
    defer board.deinit();
    var output = try Output.init();
    defer output.deinit();
    var run: audio_out.Run = .{};
    run.arm(&board, .{ .path = output.path, .rate = 22050 });
    defer run.deinit();
    board.audio.write(ch0 + ssie.off_ssicr, 4, ssicr(1, 0, true));
    send(&board, &.{ 0x1111, 0x2222, 0x3333, 0x4444 });
    try run.finish(&output.said.writer, std.testing.io);
    const bytes = try output.file();
    defer allocator.free(bytes);
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, bytes[22..24], .little));
    try std.testing.expectEqual(@as(u32, 22050), std.mem.readInt(u32, bytes[24..28], .little));
    try std.testing.expectEqual(@as(u16, 16), std.mem.readInt(u16, bytes[34..36], .little));
    try std.testing.expectEqualSlices(u8, &.{ 0x11, 0x11, 0x22, 0x22, 0x33, 0x33, 0x44, 0x44 }, bytes[44..]);
    try std.testing.expect(std.mem.indexOf(u8, output.said.written(), "4 sample(s), 22050 Hz, 16-bit, 2 channel(s), 0 silent") != null);
}

test "samples a quiet stretch of virtual time skipped come out as silence" {
    var board = ra8.board.board.Board.init(allocator);
    defer board.deinit();
    var output = try Output.init();
    defer output.deinit();
    var run: audio_out.Run = .{};
    run.arm(&board, .{ .path = output.path, .rate = 1000 });
    defer run.deinit();
    board.audio.write(ch0 + ssie.off_ssicr, 4, ssicr(1, 0, true));
    send(&board, &.{ 0x1111, 0x2222 });
    const before = board.time.base.now();
    while (board.time.base.now() - before < 3 * std.time.ns_per_ms) board.time.base.advance(1000);
    send(&board, &.{ 0x3333, 0x4444 });
    try std.testing.expect(run.recorder.?.silent >= 4);
    try std.testing.expectEqual(@as(u32, 0x3333), run.recorder.?.samples.items[run.recorder.?.samples.items.len - 2]);
}

test "a prohibited DWL is reported and no file is written" {
    var board = ra8.board.board.Board.init(allocator);
    defer board.deinit();
    var output = try Output.init();
    defer output.deinit();
    var run: audio_out.Run = .{};
    run.arm(&board, .{ .path = output.path });
    defer run.deinit();
    board.audio.write(ch0 + ssie.off_ssicr, 4, ssicr(7, 0, false));
    send(&board, &.{0x1111});
    try run.finish(&output.said.writer, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, output.said.written(), "prohibited 111b; ") != null);
    try std.testing.expectError(error.FileNotFound, output.file());
}

test "a shape change mid-stream stops the recording and keeps what came before" {
    var board = ra8.board.board.Board.init(allocator);
    defer board.deinit();
    var output = try Output.init();
    defer output.deinit();
    var run: audio_out.Run = .{};
    run.arm(&board, .{ .path = output.path });
    defer run.deinit();
    board.audio.write(ch0 + ssie.off_ssicr, 4, ssicr(1, 0, true));
    send(&board, &.{ 0x1111, 0x2222 });
    board.audio.write(ch0 + ssie.off_ssicr, 4, ssicr(5, 0, true));
    send(&board, &.{ 0x3333, 0x4444 });
    try run.finish(&output.said.writer, std.testing.io);
    try std.testing.expectEqual(audio_out.Stop.shape_changed, run.stop);
    const bytes = try output.file();
    defer allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 44 + 4), bytes.len);
    try std.testing.expect(std.mem.indexOf(u8, output.said.written(), "stopped early: SSICR changed") != null);
}

test "with no path the board is left without a listener and nothing is said" {
    var board = ra8.board.board.Board.init(allocator);
    defer board.deinit();
    var run: audio_out.Run = .{};
    run.arm(&board, .{});
    defer run.deinit();
    try std.testing.expect(board.audio.channels[0].listener == null);
    var said: std.Io.Writer.Allocating = .init(allocator);
    defer said.deinit();
    try run.finish(&said.writer, std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), said.written().len);
}
