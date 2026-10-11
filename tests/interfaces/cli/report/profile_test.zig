//! RA8EMU-1143: the `--profile-folded` file is written on its own, so a
//! `--report json` run on the Zig core still leaves it beside the report.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");

const elf = ra8.board.image.elf;
const profile = ra8.session.functions.profile;
const symbols = ra8.session.symbols;
const report_profile = cli_app.report.profile;

const gpa = std.testing.allocator;
const image_bytes = @embedFile("../../../fixtures/profile/call_tree.elf");

test "writeFolded writes one row per function, heaviest counts kept" {
    const image = try elf.Image.init(image_bytes);
    var table = profile.Table{ .image = image };
    table.add(symbols.addressOf(image, "heavy").?, 30, 30);
    table.add(symbols.addressOf(image, "light").?, 10, 10);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/run.folded", .{tmp.sub_path});
    defer gpa.free(path);
    try report_profile.writeFolded(std.testing.io, image, table, path);
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "run.folded", gpa, .limited(4096));
    defer gpa.free(bytes);
    try std.testing.expect(std.mem.endsWith(u8, firstLine(bytes), "heavy 30"));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "light 10\n") != null);
}

test "writeFolded with no counts still creates the file" {
    const image = try elf.Image.init(image_bytes);
    const table = profile.Table{ .image = image };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/empty.folded", .{tmp.sub_path});
    defer gpa.free(path);
    try report_profile.writeFolded(std.testing.io, image, table, path);
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "empty.folded", gpa, .limited(4096));
    defer gpa.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), bytes.len);
}

fn firstLine(bytes: []const u8) []const u8 {
    return bytes[0 .. std.mem.indexOfScalar(u8, bytes, '\n') orelse bytes.len];
}
