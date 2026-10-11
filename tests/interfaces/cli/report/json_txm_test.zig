//! Covers src/interfaces/cli/report/json_txm.zig: the `modules` array
//! of `--report json`, left out when nothing is loaded and one entry per
//! module when something is, parsed back with std.json.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");

const json_run = cli_app.report.json_run;
const txm = ra8.session.txm_modules;
const txm_report = ra8.session.txm_report;
const Value = std.json.Value;
const Fixture = @import("json_board.zig").Fixture;

const base: u32 = 0x2000_0000;
const head_at: u32 = base;
const first: u32 = base + 0x100;
const name_at: u32 = first + 1180;
const size = name_at - base + 16;

const Window = struct {
    bytes: []const u8,

    pub fn read(self: Window, address: u32, into: []u8) bool {
        if (address < base) return false;
        const at = address - base;
        if (at + into.len > self.bytes.len) return false;
        @memcpy(into, self.bytes[at .. at + into.len]);
        return true;
    }
};

fn put(bytes: *[size]u8, at: u32, value: u32) void {
    std.mem.writeInt(u32, bytes[at - base ..][0..4], value, .little);
}

fn oneModule() [size]u8 {
    var bytes = @as([size]u8, @splat(0));
    put(&bytes, head_at, first);
    put(&bytes, first + txm.offset.id, txm.instance_id);
    put(&bytes, first + txm.offset.name, name_at);
    put(&bytes, first + txm.offset.state, 2);
    put(&bytes, first + txm.offset.code_start, 0x6001_0000);
    put(&bytes, first + txm.offset.code_size, 2048);
    put(&bytes, first + txm.offset.data_start, 0x2004_0000);
    put(&bytes, first + txm.offset.data_size, 1024);
    put(&bytes, first + txm.offset.loaded_next, first);
    @memcpy(bytes[name_at - base ..][0..5], "hello");
    return bytes;
}

fn render(board: *ra8.board.board.Board, modules: ?*const txm_report.Listed, buf: *std.Io.Writer.Allocating) !std.json.Parsed(Value) {
    try json_run.document(&buf.writer, board, .{ .engine = "zig", .elapsed = 1, .modules = modules });
    return std.json.parseFromSlice(Value, std.testing.allocator, buf.written(), .{});
}

test "no modules leaves the key out" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const empty = txm_report.Listed{};
    const doc = try render(&fix.board, &empty, &buf);
    defer doc.deinit();
    try std.testing.expect(doc.value.object.get("modules") == null);
}

test "one loaded module is one entry with its name, state and extents" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    const bytes = oneModule();
    const listed = txm_report.list(head_at, Window{ .bytes = &bytes });
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(&fix.board, &listed, &buf);
    defer doc.deinit();
    const entries = doc.value.object.get("modules").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    const entry = entries[0].object;
    try std.testing.expectEqualStrings("hello", entry.get("name").?.string);
    try std.testing.expectEqualStrings("started", entry.get("state").?.string);
    try std.testing.expectEqual(@as(i64, 0x6001_0000), entry.get("code_start").?.integer);
    try std.testing.expectEqual(@as(i64, 2048), entry.get("code_size").?.integer);
    try std.testing.expectEqual(@as(i64, 0x2004_0000), entry.get("data_start").?.integer);
    try std.testing.expectEqual(@as(i64, 1024), entry.get("data_size").?.integer);
}
