//! Covers src/interfaces/cli/report/json/json.zig: commas, nesting, escaping and
//! the scalar forms the report writes.
const std = @import("std");
const cli_app = @import("cli_app");

const json = cli_app.report.json;

test "objects and arrays get commas between items and none after the last" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    var j = json.over(&buf.writer);
    try j.open(null, '{');
    try j.field("a", @as(u32, 1));
    try j.open("list", '[');
    try j.field(null, true);
    try j.field(null, false);
    try j.close(']');
    try j.open("empty", '{');
    try j.close('}');
    try j.field("b", @as(?u64, null));
    try j.close('}');
    try std.testing.expectEqualStrings("{\"a\":1,\"list\":[true,false],\"empty\":{},\"b\":null}", buf.written());
}

test "strings are escaped so the document always parses" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try json.string(&buf.writer, "a\"b\\c\nd\x01");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\u0001\"", buf.written());
    const back = try std.json.parseFromSlice([]const u8, std.testing.allocator, buf.written(), .{});
    defer back.deinit();
    try std.testing.expectEqualStrings("a\"b\\c\nd\x01", back.value);
}

test "optionals with a value print the value" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    var j = json.over(&buf.writer);
    try j.open(null, '[');
    try j.field(null, @as(?u64, 7));
    try j.field(null, "x");
    try j.close(']');
    try std.testing.expectEqualStrings("[7,\"x\"]", buf.written());
}
