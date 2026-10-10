//! Host tests for the time bar's speed field (RA8EMU-808): what it accepts
//! and refuses, how it reads, and speeds applied to a spawned `serve
//! --stdio` session over the link.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const test_paths = @import("test_paths");
const proto = ra8.rpc.session_rpc;
const session_link = gui_app.session_link;
const speed_field = gui_app.speed_field;
const Link = session_link.Link;
const Field = speed_field.Field;
const Env = proto.Client.Env;

const elf_path = "tests/fixtures/fpu/fp_basic.elf";

test "the field takes the range --speed takes, and max" {
    try std.testing.expectEqual(@as(?u64, 250), speed_field.parse("0.25"));
    try std.testing.expectEqual(@as(?u64, 5000), speed_field.parse("5"));
    try std.testing.expectEqual(@as(?u64, 100_000), speed_field.parse("100"));
    try std.testing.expectEqual(@as(?u64, 1), speed_field.parse("0.001"));
    try std.testing.expectEqual(@as(?u64, 0), speed_field.parse("max"));
    try std.testing.expectEqual(@as(?u64, 0), speed_field.parse("MAX"));
    for ([_][]const u8{ "0", "-1", "1e9", "abc", "0.0004", "1.2.3", "", "inf", "nan" }) |bad| {
        try std.testing.expectEqual(@as(?u64, null), speed_field.parse(bad));
    }
}

test "the field keeps digits, one dot and max, and reads the speed in use" {
    var buf: [32]u8 = undefined;
    var field: Field = .{};
    try std.testing.expectEqualStrings("1x", try field.shown(&buf));
    field.typed("-0.2.5e");
    try std.testing.expectEqualStrings("0.25", field.text());
    field.len = 0;
    field.typed("MaX");
    try std.testing.expectEqualStrings("max", field.text());
    try std.testing.expectEqualStrings("0.25x", try speed_field.format(250, &buf));
    try std.testing.expectEqualStrings("0.001x", try speed_field.format(1, &buf));
    try std.testing.expectEqualStrings("12.5x", try speed_field.format(12_500, &buf));
    try std.testing.expectEqualStrings("max", try speed_field.format(0, &buf));
}

fn connect(link: *Link) !void {
    const deadline = std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() + 10_000;
    while (link.state == .connecting and std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() < deadline) {
        _ = link.pump();
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(link.state == .connected);
}

/// Pump the link into the field until the session answers, for ten seconds.
fn settle(link: *Link, field: *Field) !void {
    const deadline = std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() + 10_000;
    while (field.ask_id != null) {
        if (std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() > deadline) return error.Timeout;
        if (link.state != .connected) return error.LinkLost;
        if (link.pump()) |arrival| field.observe(arrival) else try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
}

fn enter(link: *Link, field: *Field, text: []const u8) !speed_field.Outcome {
    field.typed(text);
    const outcome = try field.key(link, speed_field.codes.enter);
    try settle(link, field);
    return outcome;
}

test "speeds typed into the field reach a local session, and bad ones never leave it" {
    const gpa = std.testing.allocator;
    var local: session_link.Local = undefined;
    try local.spawn(std.testing.io, test_paths.emulator, elf_path);
    errdefer local.child.kill(std.testing.io);
    const rx = try gpa.alloc(u8, 2 * Env.max_frame);
    defer gpa.free(rx);
    const tx = try gpa.alloc(u8, Env.max_frame);
    defer gpa.free(tx);
    var link: Link = undefined;
    link.open(local.transport(), rx, tx);
    try connect(&link);

    var buf: [32]u8 = undefined;
    var field: Field = .{};
    try std.testing.expectEqual(speed_field.Outcome.sent, try enter(&link, &field, "0.25"));
    try std.testing.expectEqual(@as(u64, 250), field.applied);
    try std.testing.expectEqualStrings("0.25x", try field.shown(&buf));
    try std.testing.expectEqual(speed_field.Outcome.sent, try enter(&link, &field, "max"));
    try std.testing.expectEqualStrings("max", try field.shown(&buf));
    try std.testing.expectEqual(@as(?speed_field.Refusal, null), field.refused);

    try std.testing.expectEqual(speed_field.Outcome.refused, try enter(&link, &field, "0"));
    try std.testing.expectEqual(@as(?u32, null), field.ask_id);
    try std.testing.expectEqual(@as(?speed_field.Refusal, .invalid), field.refused);
    try std.testing.expectEqualStrings("0", try field.shown(&buf));
    try std.testing.expectEqual(speed_field.Outcome.cancel, try field.key(&link, speed_field.codes.escape));
    try std.testing.expectEqualStrings("max", try field.shown(&buf));

    local.end();
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try local.reap());
}
