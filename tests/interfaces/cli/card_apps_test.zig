//! `--app` admits each .ra8app's header before boot and lays the apps in the
//! SDHI card's root beside the --sd-dir folder (RA8EMU-1138).
const std = @import("std");
const io = std.testing.io;
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const ra8app = ra8.board.image.ra8app;
const card_apps = cli_app.card_apps;

const code_len = 16;
const data_len = 8;
const image_len = ra8app.header_len + code_len + data_len;

fn sample() [image_len]u8 {
    var bytes = @as([image_len]u8, @splat(0));
    const words = [_]u32{ ra8app.magic, ra8app.version, 4, code_len, data_len, 0x800, 1, ra8app.Capability.display };
    for (words, 0..) |value, index| std.mem.writeInt(u32, bytes[index * 4 ..][0..4], value, .little);
    @memcpy(bytes[32..][0..9], "com.hello");
    @memcpy(bytes[64..][0..5], "Hello");
    return bytes;
}

fn pathIn(tmp: std.testing.TmpDir, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
}

test "an admitted app keeps its file name and bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = sample();
    try tmp.dir.writeFile(io, .{ .sub_path = "hello.ra8app", .data = &bytes });
    const path = try pathIn(tmp, "hello.ra8app");
    defer std.testing.allocator.free(path);
    var out: [card_apps.max_apps]card_apps.Staged = undefined;
    const apps = try card_apps.load(io, std.testing.allocator, &.{path}, &out);
    defer card_apps.unload(std.testing.allocator, apps);
    try std.testing.expectEqual(@as(usize, 1), apps.len);
    try std.testing.expectEqualStrings("hello.ra8app", apps[0].name);
    try std.testing.expectEqualSlices(u8, &bytes, apps[0].bytes);
}

test "an app the firmware would refuse never reaches the card" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var bytes = sample();
    bytes[0] ^= 0xff;
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.ra8app", .data = &bytes });
    const path = try pathIn(tmp, "bad.ra8app");
    defer std.testing.allocator.free(path);
    var out: [card_apps.max_apps]card_apps.Staged = undefined;
    try std.testing.expectError(error.Validation, card_apps.load(io, std.testing.allocator, &.{path}, &out));
}

test "a short app is refused as the firmware refuses it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = sample();
    try tmp.dir.writeFile(io, .{ .sub_path = "short.ra8app", .data = bytes[0 .. image_len - 1] });
    const path = try pathIn(tmp, "short.ra8app");
    defer std.testing.allocator.free(path);
    var out: [card_apps.max_apps]card_apps.Staged = undefined;
    try std.testing.expectError(error.ShortImage, card_apps.load(io, std.testing.allocator, &.{path}, &out));
}

test "with no folder the root holds just the apps" {
    const bytes = sample();
    const root: card_apps.Root = .{ .base = null, .apps = &.{.{ .name = "hello.ra8app", .bytes = &bytes }} };
    const entries = try root.list(std.testing.allocator);
    defer card_apps.Root.free(std.testing.allocator, entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("hello.ra8app", entries[0].name);
    try std.testing.expectEqual(@as(u64, image_len), try root.size("hello.ra8app"));
    const read = try root.read(std.testing.allocator, "hello.ra8app");
    defer std.testing.allocator.free(read);
    try std.testing.expectEqualSlices(u8, &bytes, read);
    try std.testing.expectError(error.FileNotFound, root.size("other.bin"));
}

test "apps join the folder's files and a name clash is refused" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "hi" });
    const bytes = sample();
    const folder = ra8.host.folder.Folder.of(io, tmp.dir);
    const root: card_apps.Root = .{ .base = folder, .apps = &.{.{ .name = "hello.ra8app", .bytes = &bytes }} };
    const entries = try root.list(std.testing.allocator);
    defer card_apps.Root.free(std.testing.allocator, entries);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(@as(u64, 2), try root.size("notes.txt"));
    const clash: card_apps.Root = .{ .base = folder, .apps = &.{.{ .name = "notes.txt", .bytes = &bytes }} };
    try std.testing.expectError(error.AppNameTaken, clash.list(std.testing.allocator));
}

test "two apps with one file name are refused" {
    const bytes = sample();
    const app: card_apps.Staged = .{ .name = "hello.ra8app", .bytes = &bytes };
    const root: card_apps.Root = .{ .base = null, .apps = &.{ app, app } };
    try std.testing.expectError(error.AppNameTaken, root.list(std.testing.allocator));
}

test "an --app value splits into the app and its module ELF" {
    const paired = card_apps.split("out/hello.ra8app=out/hello.elf");
    try std.testing.expectEqualStrings("out/hello.ra8app", paired.app);
    try std.testing.expectEqualStrings("out/hello.elf", paired.elf.?);
    const alone = card_apps.split("out/hello.ra8app");
    try std.testing.expectEqualStrings("out/hello.ra8app", alone.app);
    try std.testing.expectEqual(@as(?[]const u8, null), alone.elf);
}

test "a paired app keeps its module ELF under the header's display name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = sample();
    try tmp.dir.writeFile(io, .{ .sub_path = "hello.ra8app", .data = &bytes });
    try tmp.dir.writeFile(io, .{ .sub_path = "hello.elf", .data = "module elf" });
    const app = try pathIn(tmp, "hello.ra8app");
    defer std.testing.allocator.free(app);
    const value = try std.fmt.allocPrint(std.testing.allocator, "{s}=.zig-cache/tmp/{s}/hello.elf", .{ app, tmp.sub_path });
    defer std.testing.allocator.free(value);
    var out: [card_apps.max_apps]card_apps.Staged = undefined;
    const apps = try card_apps.load(io, std.testing.allocator, &.{value}, &out);
    defer card_apps.unload(std.testing.allocator, apps);
    try std.testing.expectEqualStrings("hello.ra8app", apps[0].name);
    try std.testing.expectEqualStrings("Hello", apps[0].label);
    try std.testing.expectEqualStrings("module elf", apps[0].elf.?);
}
