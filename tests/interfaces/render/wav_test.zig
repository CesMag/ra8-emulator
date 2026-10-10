//! Tests for src/interfaces/render/wav.zig: the header, a tone read back from
//! the file, and silence where the stream underran.
const std = @import("std");
const ra8 = @import("ra8");
const wav = ra8.board.report.wav;

const allocator = std.testing.allocator;

fn encode(recorder: *const wav.Recorder) !std.Io.Writer.Allocating {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try recorder.write(&out.writer);
    return out;
}

fn le32(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

fn le16(bytes: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, bytes[at..][0..2], .little);
}

test "formats a WAV cannot carry as signed PCM are refused" {
    const bad = [_]wav.Format{
        .{ .rate = 48000, .bits = 8, .channels = 2 },
        .{ .rate = 48000, .bits = 12, .channels = 2 },
        .{ .rate = 0, .bits = 16, .channels = 2 },
        .{ .rate = 48000, .bits = 16, .channels = 0 },
    };
    for (bad) |format| try std.testing.expectError(error.BadFormat, wav.Recorder.init(format));
}

test "the header names the format and the data length" {
    var r = try wav.Recorder.init(.{ .rate = 48000, .bits = 24, .channels = 2 });
    defer r.deinit(allocator);
    for (0..5) |i| try r.push(allocator, 0, @intCast(0x00ABCDE0 + i));
    var out = try encode(&r);
    defer out.deinit();
    const b = out.written();
    try std.testing.expectEqualStrings("RIFF", b[0..4]);
    try std.testing.expectEqualStrings("WAVEfmt ", b[8..16]);
    try std.testing.expectEqual(@as(u16, 1), le16(b, 20));
    try std.testing.expectEqual(@as(u16, 2), le16(b, 22));
    try std.testing.expectEqual(@as(u32, 48000), le32(b, 24));
    try std.testing.expectEqual(@as(u32, 48000 * 6), le32(b, 28));
    try std.testing.expectEqual(@as(u16, 6), le16(b, 32));
    try std.testing.expectEqual(@as(u16, 24), le16(b, 34));
    try std.testing.expectEqualStrings("data", b[36..40]);
    // Five samples are two whole stereo frames; the fifth is half a frame.
    try std.testing.expectEqual(@as(u32, 12), le32(b, 40));
    try std.testing.expectEqual(@as(u32, 36 + 12), le32(b, 4));
    try std.testing.expectEqual(@as(usize, 44 + 12), b.len);
    try std.testing.expectEqualSlices(u8, &.{ 0xE0, 0xCD, 0xAB }, b[44..47]);
}

test "a 1 kHz tone reads back as 1 kHz for a quarter second" {
    const rate = 8000;
    var r = try wav.Recorder.init(.{ .rate = rate, .bits = 16, .channels = 1 });
    defer r.deinit(allocator);
    const count = rate / 4;
    for (0..count) |i| {
        const t = @as(f64, @floatFromInt(i)) / rate;
        const level: i16 = @intFromFloat(@round(12000 * @sin(2 * std.math.pi * 1000 * t - 0.3)));
        const ns = @as(u64, i) * std.time.ns_per_s / rate;
        try r.push(allocator, ns, @as(u16, @bitCast(level)));
    }
    var out = try encode(&r);
    defer out.deinit();
    const data = out.written()[44..];
    const samples = data.len / 2;
    try std.testing.expectEqual(@as(usize, count), samples);
    try std.testing.expectEqual(@as(u64, 0), r.silent);
    var rising: usize = 0;
    var before: i16 = @bitCast(le16(data, 0));
    for (1..samples) |i| {
        const now: i16 = @bitCast(le16(data, i * 2));
        if (before < 0 and now >= 0) rising += 1;
        before = now;
    }
    // 0.25 s of 1 kHz is 250 cycles. The tone starts just below zero, so
    // each cycle's rising edge falls inside the quarter second.
    try std.testing.expectEqual(@as(usize, 250), rising);
}

test "slots the stream skipped come out as silence" {
    var r = try wav.Recorder.init(.{ .rate = 1000, .bits = 16, .channels = 1 });
    defer r.deinit(allocator);
    for (0..3) |i| try r.push(allocator, i * std.time.ns_per_ms, 0x1111);
    try r.push(allocator, 10 * std.time.ns_per_ms, 0x2222);
    try std.testing.expectEqual(@as(usize, 11), r.samples.items.len);
    try std.testing.expectEqual(@as(u64, 7), r.silent);
    for (r.samples.items[3..10]) |s| try std.testing.expectEqual(@as(u32, 0), s);
    try std.testing.expectEqual(@as(u32, 0x2222), r.samples.items[10]);
}

test "an underrun pads whole stereo frames, so left stays left" {
    var r = try wav.Recorder.init(.{ .rate = 1000, .bits = 16, .channels = 2 });
    defer r.deinit(allocator);
    try r.push(allocator, 0, 0xAAAA);
    try r.push(allocator, 0, 0xBBBB);
    try r.push(allocator, 5 * std.time.ns_per_ms, 0xAAAA);
    try std.testing.expectEqual(@as(u64, 8), r.silent);
    try std.testing.expectEqual(@as(usize, 11), r.samples.items.len);
    try std.testing.expectEqual(@as(u32, 0xAAAA), r.samples.items[10]);
}

test "a burst early for its slots goes where the stream is, with no silence" {
    var r = try wav.Recorder.init(.{ .rate = 48000, .bits = 32, .channels = 2 });
    defer r.deinit(allocator);
    for (0..4) |i| try r.push(allocator, 1000, @intCast(i));
    try std.testing.expectEqual(@as(usize, 4), r.samples.items.len);
    try std.testing.expectEqual(@as(u64, 0), r.silent);
}
