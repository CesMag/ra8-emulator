//! Covers src/interfaces/cli/report/undefined.zig: the `--stop-on-undefined`
//! lines a Zig run prints about the sites the sweep found.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const undefined_ops = ra8.chip.core.undefined_ops;
const report = cli_app.report.undefined_sites;
const imageWith = @import("../../../chip/core/undefined_image.zig").imageWith;

test "nothing found prints nothing" {
    var buffer: [256]u8 = undefined;
    const image = imageWith(&buffer, &[_]u8{ 0x10, 0x46 }, 0x02007000);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try report.print(&out.writer, image, .{});
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}

test "a site prints its address and its encoding" {
    var found = undefined_ops.Found{};
    found.sites[0] = .{ .address = 0x02007498, .encoding = 0xEA02038F };
    found.count = 1;
    var buffer: [256]u8 = undefined;
    const image = imageWith(&buffer, &[_]u8{ 0x10, 0x46 }, 0x02007000);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try report.print(&out.writer, image, found);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "1 site(s)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "0x02007498 EA02038F") != null);
}

test "an image with no symbol table prints the address alone" {
    var found = undefined_ops.Found{};
    found.sites[0] = .{ .address = 0x02007002, .encoding = 0xEA02038F };
    found.count = 1;
    var buffer: [256]u8 = undefined;
    const image = imageWith(&buffer, &[_]u8{ 0x10, 0x46 }, 0x02007000);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try report.print(&out.writer, image, found);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "+0x") == null);
}

test "an executed site is marked and counted in the summary" {
    var found = undefined_ops.Found{};
    found.sites[0] = .{ .address = 0x02007498, .encoding = 0xEA02038F, .runs = 2 };
    found.count = 1;
    var buffer: [256]u8 = undefined;
    const image = imageWith(&buffer, &[_]u8{ 0x10, 0x46 }, 0x02007000);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try report.print(&out.writer, image, found);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "EXECUTED 2x") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "1 of them EXECUTED, 2 arrival(s)") != null);
}

test "a swept but unexecuted site reports none executed" {
    var found = undefined_ops.Found{};
    found.sites[0] = .{ .address = 0x02007498, .encoding = 0xEA02038F };
    found.count = 1;
    var buffer: [256]u8 = undefined;
    const image = imageWith(&buffer, &[_]u8{ 0x10, 0x46 }, 0x02007000);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try report.print(&out.writer, image, found);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "none executed") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "EXECUTED") == null);
}

test "the report names the site the run stopped on" {
    var buffer: [4096]u8 = undefined;
    var image_bytes: [512]u8 = undefined;
    const image = imageWith(&image_bytes, &[_]u8{ 0x02, 0xEA, 0x8F, 0x03 }, 0x0200_0000);

    var found = undefined_ops.Found{};
    found.sites[0] = .{ .address = 0x0200_0000, .encoding = 0xEA02_038F };
    found.count = 1;
    found.stopOnRun();
    found.sites[0].runs = 1;

    var stream: std.Io.Writer = .fixed(&buffer);
    try report.print(&stream, image, found);
    const out = stream.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "run stopped at 0x02000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "before it executed") != null);
}

test "a run that was not stopped says nothing about stopping" {
    var buffer: [4096]u8 = undefined;
    var image_bytes: [512]u8 = undefined;
    const image = imageWith(&image_bytes, &[_]u8{ 0x02, 0xEA, 0x8F, 0x03 }, 0x0200_0000);

    var found = undefined_ops.Found{};
    found.sites[0] = .{ .address = 0x0200_0000, .encoding = 0xEA02_038F };
    found.count = 1;
    found.sites[0].runs = 1;

    var stream: std.Io.Writer = .fixed(&buffer);
    try report.print(&stream, image, found);
    try std.testing.expect(std.mem.indexOf(u8, stream.buffered(), "run stopped at") == null);
}
