//! Host tests for the shell's side of File > Open ELF (RA8EMU-959): the
//! shortcut asks for the picker once, the frame puts it up and keeps the
//! window's title on the image in use, and a file that cannot be read or is
//! too long for a load is turned back before the session link is touched.
//! shell_open_live_test.zig loads picked images into a real session.
const std = @import("std");
const gui_app = @import("gui_app");
const Open = gui_app.shell.open.Open;
const Status = gui_app.status.bar.Status;
const Image = gui_app.status.bar.Image;
const Link = gui_app.session_link.Link;
const Headless = gui_app.headless.Headless;
const Event = gui_app.platform.Event;

fn model() Open {
    return .{ .io = std.testing.io, .allocator = std.testing.allocator };
}

fn chord(code: u32, down: bool, primary: bool) Event {
    return .{ .key = .{ .code = code, .down = down, .primary = primary } };
}

test "the OS's modifier with O asks for the picker; nothing else does" {
    var open = model();
    try std.testing.expect(!open.key(chord('o', true, false)));
    try std.testing.expect(!open.key(chord('p', true, true)));
    try std.testing.expect(!open.key(chord('o', false, true)));
    try std.testing.expect(!open.key(.{ .text = gui_app.platform.Text.of("o") }));
    try std.testing.expect(!open.asked);
    try std.testing.expect(open.key(chord('o', true, true)));
    try std.testing.expect(open.asked);
}

test "the frame puts the picker up once for each time it was asked for" {
    var window = Headless.init(std.testing.allocator, 8, 8);
    defer window.deinit();
    var open = model();
    var status: Status = .{};
    open.frame(window.platform(), &status);
    try std.testing.expectEqual(@as(u32, 0), window.pickers);
    open.ask();
    open.frame(window.platform(), &status);
    open.frame(window.platform(), &status);
    try std.testing.expectEqual(@as(u32, 1), window.pickers);
    try std.testing.expect(open.key(chord('o', true, true)));
    open.frame(window.platform(), &status);
    try std.testing.expectEqual(@as(u32, 2), window.pickers);
}

test "the window's title names the image in use and follows a new one" {
    var window = Headless.init(std.testing.allocator, 8, 8);
    defer window.deinit();
    var open = model();
    var status: Status = .{};
    open.frame(window.platform(), &status);
    try std.testing.expectEqualStrings("", window.title());
    status.image = Image.of("build/app.elf", "one");
    open.frame(window.platform(), &status);
    try std.testing.expectEqualStrings("app.elf - ra8 emulator", window.title());
    window.platform().title("left alone");
    open.frame(window.platform(), &status);
    try std.testing.expectEqualStrings("left alone", window.title());
    // The same name with other bytes is another image.
    status.image = Image.of("build/app.elf", "two");
    open.frame(window.platform(), &status);
    try std.testing.expectEqualStrings("app.elf - ra8 emulator", window.title());
    status.image = Image.of("/tmp/other.axf", "two");
    open.frame(window.platform(), &status);
    try std.testing.expectEqualStrings("other.axf - ra8 emulator", window.title());
}

test "a file that cannot be read never reaches the session" {
    var open = model();
    var status: Status = .{};
    status.image = Image.of("app.elf", "abc");
    // The link is never opened: nothing may be sent on it.
    var link: Link = undefined;
    open.picked("/nonexistent/ra8-open/missing.elf", &link, &status);
    try std.testing.expectEqual(@as(?gui_app.status.bar.Refusal, .unread), status.refused);
    try std.testing.expectEqual(@as(?u32, null), status.load_id);
    try std.testing.expectEqualStrings("app.elf", status.image.?.name());
}

test "a file longer than one load carries is turned back before the link" {
    const gpa = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const limit = @import("ra8").rpc.session.rpc.Load.max_len.image;
    const long = try gpa.alloc(u8, limit + 1);
    defer gpa.free(long);
    @memset(long, 0);
    try dir.dir.writeFile(std.testing.io, .{ .sub_path = "long.elf", .data = long });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try dir.dir.realPathFile(std.testing.io, "long.elf", &path_buf)];
    var open = model();
    var status: Status = .{};
    var link: Link = undefined;
    open.picked(path, &link, &status);
    try std.testing.expectEqual(@as(?gui_app.status.bar.Refusal, .too_large), status.refused);
    try std.testing.expectEqual(@as(?u32, null), status.load_id);
    var line: [256]u8 = undefined;
    try std.testing.expect(std.mem.endsWith(u8, try status.text(.connecting, &line), "| the image is too large for the session (1 MiB at most)"));
}
