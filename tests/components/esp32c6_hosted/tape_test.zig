//! Tape files for recorded C6 host traffic (RA8EMU-560).
const std = @import("std");
const ra8 = @import("ra8");
const tape = ra8.components.esp_hosted.tape;
const tape_dir = ra8.host.tape_dir;

const web = tape.Key{ .proto = .tcp, .ip = .{ 93, 184, 216, 34 }, .port = 80 };

fn scratch(tmp: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    const len = try tmp.dir.realPath(std.testing.io, buf);
    return buf[0..len];
}

fn openTape(path: []const u8, mode: tape.Mode) !tape.Tape {
    return .init(mode, .of(tape_dir, try tape_dir.open(std.testing.io, path, mode == .record)));
}

test "a recorded connection reads back record by record" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try scratch(&tmp, &buf);
    var recorder = try openTape(path, .record);
    defer recorder.deinit();
    var writer = try recorder.create(web);
    writer.put(.guest, "GET / HTTP/1.0\r\n\r\n");
    writer.put(.host, "HTTP/1.0 200 OK\r\n");
    writer.put(.host, "\r\nhello");
    writer.put(.closed, "");
    writer.close();

    var player = try openTape(path, .replay);
    defer player.deinit();
    var reader = try player.load(web);
    defer reader.deinit();
    var out: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), reader.take(&out));
    try std.testing.expect(reader.expect("GET / "));
    try std.testing.expect(reader.expect("HTTP/1.0\r\n\r\n"));
    const first = reader.take(&out);
    try std.testing.expectEqualStrings("HTTP/1.0 200 OK\r\n", out[0..first]);
    try std.testing.expect(!reader.closed());
    const second = reader.take(&out);
    try std.testing.expectEqualStrings("\r\nhello", out[0..second]);
    try std.testing.expect(reader.closed());
}

test "a guest byte that differs from the recording is refused" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try scratch(&tmp, &buf);
    var recorder = try openTape(path, .record);
    defer recorder.deinit();
    var writer = try recorder.create(web);
    writer.put(.guest, "GET /a");
    writer.close();

    var player = try openTape(path, .replay);
    defer player.deinit();
    var reader = try player.load(web);
    defer reader.deinit();
    try std.testing.expect(!reader.expect("GET /b"));
}

test "the second connection to an endpoint gets its own tape, a third is a miss" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try scratch(&tmp, &buf);
    var recorder = try openTape(path, .record);
    defer recorder.deinit();
    for ([_][]const u8{ "one", "two" }) |body| {
        var writer = try recorder.create(web);
        writer.put(.host, body);
        writer.close();
    }
    try tmp.dir.access(std.testing.io, "tcp-93.184.216.34-80-1.tape", .{});

    var player = try openTape(path, .replay);
    defer player.deinit();
    var out: [8]u8 = undefined;
    for ([_][]const u8{ "one", "two" }) |body| {
        var reader = try player.load(web);
        defer reader.deinit();
        try std.testing.expectEqualStrings(body, out[0..reader.take(&out)]);
    }
    try std.testing.expectError(error.FileNotFound, player.load(web));
    try std.testing.expectEqual(@as(u32, 1), player.missed());
}

test "a DNS answer replays under a new query id; an unknown question is a miss" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try scratch(&tmp, &buf);
    var recorder = try openTape(path, .record);
    defer recorder.deinit();
    recorder.storeDns(&.{ 0x12, 0x34, 'q' }, &.{ 0x12, 0x34, 'a', 'n' });

    var player = try openTape(path, .replay);
    defer player.deinit();
    var out: [16]u8 = undefined;
    const answer = player.loadDns(&.{ 0xAB, 0xCD, 'q' }, &out).?;
    try std.testing.expectEqualSlices(u8, &.{ 0xAB, 0xCD, 'a', 'n' }, answer);
    try std.testing.expect(player.loadDns(&.{ 0xAB, 0xCD, 'z' }, &out) == null);
    try std.testing.expectEqual(@as(u32, 1), player.missed());
}
