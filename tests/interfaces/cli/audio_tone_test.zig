//! RA8EMU-650, RA8EMU-570's done condition: tests/fixtures/audio/tone.elf
//! runs on the Zig core with the `--audio-out` recorder armed, and the WAV
//! it leaves has the tone's frequency and length at the asked rate.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const store_board = @import("store_board.zig");

const elf = ra8.board.image.elf;
const zig_run = cli_app.zig_run;
const cpu_boot = ra8.chip.core.cpu.boot;
const loader = ra8.chip.core.cpu.memory.load;
const audio_out = cli_app.report.audio_out;

const allocator = std.testing.allocator;
const image_bytes = @embedFile("../../fixtures/audio/tone.elf");
const done_at: u32 = 0x2200_0100;
const done_marker: u32 = 0x70E0_C0DE;
const rate: u32 = 48_000;
/// The image's tone: ten periods of 48 frames (see the fixture README).
const frames_per_period = 48;
const periods = 10;

/// Run the image with the recorder writing to `path`; the run's report
/// goes to `said`.
fn runTone(path: []const u8, said: *std.Io.Writer.Allocating) !void {
    const image = try elf.Image.init(image_bytes);
    var store = try store_board.Store.init(null);
    defer store.deinit();
    const core: store_board.Guest = .{ .store = &store };
    var board = ra8.board.board.Board.init(allocator);
    defer board.deinit();
    try store_board.attach(&board, core);
    const loaded = try ra8.board.image.load.read(image);
    _ = try loader.image(core, loaded.image());
    var audio: audio_out.Run = .{};
    audio.arm(&board, .{ .path = path, .rate = rate });
    defer audio.deinit();
    var timebase: ra8.chip.periph.clocks.Clocks = .{ .per_chunk = 5_000 };
    var clock: zig_run.Clock = .{ .io = std.testing.io, .memory = core, .board = &board, .timebase = &timebase };
    var ran: u64 = 0;
    var output: [1024]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&output);
    const vector_base = image.vectorBase() orelse return error.MissingVectorTable;
    _ = try cpu_boot.start(&stream, .zig, core, &board.bus, vector_base, 200_000, &ran, .{
        .boundary = clock.boundary(),
        .partitions = &board.partitions,
        .idau = &board.idau,
        .regions = &board.regions,
        .regions_ns = &board.regions_ns,
        .clears = &board.clears,
    });
    try std.testing.expectEqual(done_marker, try core.readWord(done_at));
    try audio.finish(&said.writer, std.testing.io);
}

/// Frames between each sign change of the left channel.
fn halfPeriods(data: []const u8, into: []usize) usize {
    var count: usize = 0;
    var last_change: usize = 0;
    var frame: usize = 1;
    while (frame < data.len / 4) : (frame += 1) {
        const was = std.mem.readInt(i16, data[(frame - 1) * 4 ..][0..2], .little);
        const now = std.mem.readInt(i16, data[frame * 4 ..][0..2], .little);
        if ((was < 0) == (now < 0)) continue;
        into[count] = frame - last_change;
        last_change = frame;
        count += 1;
    }
    return count;
}

test "the tone image's WAV is 1 kHz for 10 ms at a 48 kHz audio rate" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "tone.wav" });
    defer allocator.free(path);
    var said: std.Io.Writer.Allocating = .init(allocator);
    defer said.deinit();
    try runTone(path, &said);
    const bytes = try dir.dir.readFileAlloc(std.testing.io, "tone.wav", allocator, .limited(1 << 20));
    defer allocator.free(bytes);
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, bytes[22..24], .little));
    try std.testing.expectEqual(rate, std.mem.readInt(u32, bytes[24..28], .little));
    try std.testing.expectEqual(@as(u16, 16), std.mem.readInt(u16, bytes[34..36], .little));
    const data = bytes[44..];
    const frames = data.len / 4;
    // Length: 480 frames, which is 10 ms at 48 kHz.
    try std.testing.expectEqual(@as(usize, frames_per_period * periods), frames);
    try std.testing.expectEqual(@as(usize, 10), frames * 1000 / rate);
    // Frequency: every half period is 24 frames, so a period is 48 frames
    // and the tone is rate / 48 = 1000 Hz.
    var gaps: [2 * periods]usize = undefined;
    const changes = halfPeriods(data, &gaps);
    try std.testing.expectEqual(@as(usize, 2 * periods - 1), changes);
    for (gaps[0..changes]) |gap| try std.testing.expectEqual(@as(usize, frames_per_period / 2), gap);
    try std.testing.expectEqual(@as(u32, 1000), rate / (2 * @as(u32, @intCast(gaps[0]))));
    try std.testing.expectEqual(@as(i16, 0x4000), std.mem.readInt(i16, data[0..2], .little));
    try std.testing.expectEqual(@as(i16, -0x4000), std.mem.readInt(i16, data[24 * 4 ..][0..2], .little));
    try std.testing.expect(std.mem.indexOf(u8, said.written(), "960 sample(s), 48000 Hz, 16-bit, 2 channel(s), 0 silent") != null);
}
