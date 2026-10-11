//! ra8_gui's command line (RA8EMU-770, RA8EMU-1097): its arguments, the host
//! it picks (the local one unless --host names a profile in the hosts file),
//! and the whole run on a window the test hands in.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const shell_main = gui_app.shell_main;
const Profile = ra8.host.profiles.Profile;
const platform = gui_app.platform;
const Headless = gui_app.headless.Headless;

/// No RA8_HOSTS or HOME: every lookup goes through --hosts or fails.
const empty_env: std.process.Environ.Map = .{ .array_hash_map = .empty, .allocator = std.testing.allocator };

const image = "tests/fixtures/fpu/fp_basic.elf";

test "an image alone runs on the local host" {
    const args = try shell_main.parse(&.{ "ra8_gui", "app.elf" });
    try std.testing.expectEqualStrings("app.elf", args.image);
    try std.testing.expectEqual(@as(?[]const u8, null), args.host);
    try std.testing.expectEqual(Profile.local, try shell_main.pick(std.testing.allocator, std.testing.io, &empty_env, args));
}

test "the shell word in front changes nothing" {
    const args = try shell_main.parse(&.{ "ra8_gui", "shell", "--host", "lab", "app.elf" });
    try std.testing.expectEqualStrings("app.elf", args.image);
    try std.testing.expectEqualStrings("lab", args.host.?);
}

test "--host and --hosts are kept in either order around the image" {
    const args = try shell_main.parse(&.{ "ra8_gui", "--hosts", "/tmp/hosts", "app.elf", "--host", "lab" });
    try std.testing.expectEqualStrings("app.elf", args.image);
    try std.testing.expectEqualStrings("lab", args.host.?);
    try std.testing.expectEqualStrings("/tmp/hosts", args.hosts.?);
}

test "a missing image, a dangling flag, an unknown flag or a second image is refused" {
    const bad = [_][]const []const u8{
        &.{"ra8_gui"},
        &.{ "ra8_gui", "shell" },
        &.{ "ra8_gui", "app.elf", "--host" },
        &.{ "ra8_gui", "--fast", "app.elf" },
        &.{ "ra8_gui", "a.elf", "b.elf" },
        &.{ "ra8_gui", "serve", "app.elf" },
    };
    for (bad) |argv| try std.testing.expectError(error.Usage, shell_main.parse(argv));
}

test "the command line's run flags are not ra8_gui's" {
    const run_flags = [_][]const u8{ "--instructions", "--ms", "--frame-out", "--cpu1", "--ns", "--sd", "--console", "--report" };
    for (run_flags) |flag| try std.testing.expectError(error.Usage, shell_main.parse(&.{ "ra8_gui", "app.elf", flag, "1" }));
}

test "--frames keeps a count above zero" {
    const args = try shell_main.parse(&.{ "ra8_gui", "--frames", "5", "app.elf" });
    try std.testing.expectEqual(@as(?u32, 5), args.frames);
    try std.testing.expectEqual(@as(?u32, null), (try shell_main.parse(&.{ "ra8_gui", "app.elf" })).frames);
    try std.testing.expectError(error.Usage, shell_main.parse(&.{ "ra8_gui", "--frames", "0", "app.elf" }));
    try std.testing.expectError(error.Usage, shell_main.parse(&.{ "ra8_gui", "--frames", "many", "app.elf" }));
}

test "--theme picks dark, light or system and dark is the default" {
    const colors = @import("gui_app").colors;
    try std.testing.expectEqual(colors.Choice.dark, (try shell_main.parse(&.{ "ra8_gui", "app.elf" })).theme);
    try std.testing.expectEqual(colors.Choice.light, (try shell_main.parse(&.{ "ra8_gui", "--theme", "light", "app.elf" })).theme);
    try std.testing.expectEqual(colors.Choice.dark, (try shell_main.parse(&.{ "ra8_gui", "--theme", "dark", "app.elf" })).theme);
    try std.testing.expectEqual(colors.Choice.system, (try shell_main.parse(&.{ "ra8_gui", "--theme", "system", "app.elf" })).theme);
    try std.testing.expectError(error.Usage, shell_main.parse(&.{ "ra8_gui", "--theme", "sepia", "app.elf" }));
}

test "the host named local needs no hosts file" {
    const args = try shell_main.parse(&.{ "ra8_gui", "--host", "local", "--hosts", "/nonexistent/hosts", "app.elf" });
    try std.testing.expectEqual(Profile.local, try shell_main.pick(std.testing.allocator, std.testing.io, &empty_env, args));
}

test "any other host comes from the hosts file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.writeFile(std.testing.io, .{ .sub_path = "hosts", .data = "local here\nssh lab bsikar@labvm\n" });
    const file = try dir.dir.realPathFileAlloc(std.testing.io, "hosts", gpa);
    const lab = try shell_main.pick(gpa, std.testing.io, &empty_env, .{ .image = "app.elf", .host = "lab", .hosts = file });
    try std.testing.expectEqualStrings("bsikar@labvm", lab.ssh.destination);
    try std.testing.expectEqual(Profile.local, try shell_main.pick(gpa, std.testing.io, &empty_env, .{ .image = "app.elf", .host = "here", .hosts = file }));
    try std.testing.expectError(error.UnknownHost, shell_main.pick(gpa, std.testing.io, &empty_env, .{ .image = "app.elf", .host = "gone", .hosts = file }));
}

/// The window a test hands to `run`: headless, asking to close after
/// `quit_after` presented frames, or never. An opener has no context, so it
/// is one per test binary.
const Window = struct {
    var inner: ?Headless = null;
    var opens: u32 = 0;
    var closes: u32 = 0;
    var presents: u32 = 0;
    var asked_to_close = false;
    var quit_after: ?u32 = null;

    fn reset(quit: ?u32) void {
        opens = 0;
        closes = 0;
        presents = 0;
        asked_to_close = false;
        quit_after = quit;
    }

    fn open() ?platform.Platform {
        opens += 1;
        inner = Headless.init(std.testing.allocator, 480, 320);
        return .{ .ctx = &inner.?, .vtable = &.{ .poll = poll, .size = size, .scale = scale, .present = present } };
    }

    fn none() ?platform.Platform {
        opens += 1;
        return null;
    }

    fn close() void {
        closes += 1;
        if (inner) |*window| window.deinit();
        inner = null;
    }

    fn poll(_: *anyopaque) ?platform.Event {
        const wanted = quit_after orelse return null;
        if (asked_to_close or presents < wanted) return null;
        asked_to_close = true;
        return .quit;
    }

    fn size(_: *anyopaque) platform.Size {
        return inner.?.platform().size();
    }

    fn scale(_: *anyopaque) f32 {
        return inner.?.platform().scale();
    }

    fn present(_: *anyopaque, frame: *const ra8.render.raster.Framebuffer) anyerror!void {
        presents += 1;
        return inner.?.platform().present(frame);
    }
};

test "ra8_gui IMAGE opens the shell on the image in-process and ends when the window closes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    Window.reset(3);
    const code = try shell_main.run(arena.allocator(), std.testing.io, &empty_env, &.{ "ra8_gui", image }, .{ .open = Window.open, .close = Window.close });
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expectEqual(@as(u32, 3), Window.presents);
    try std.testing.expectEqual(@as(u32, 1), Window.opens);
    try std.testing.expectEqual(@as(u32, 1), Window.closes);
}

test "--frames ends a window nobody closes, after that many frames with the image loaded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    Window.reset(null);
    const code = try shell_main.run(arena.allocator(), std.testing.io, &empty_env, &.{ "ra8_gui", "--frames", "4", image }, .{ .open = Window.open, .close = Window.close });
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(Window.presents >= 4);
    try std.testing.expectEqual(@as(u32, 1), Window.closes);
}

test "--frames fails once the session is gone instead of waiting for a load" {
    const gpa = std.testing.allocator;
    var session: gui_app.local_session.LocalSession = undefined;
    try session.open(gpa, std.testing.io, image);
    defer session.deinit();
    const Env = ra8.rpc.session_rpc.Client.Env;
    const rx = try gpa.alloc(u8, 2 * Env.max_frame);
    defer gpa.free(rx);
    const tx = try gpa.alloc(u8, Env.max_frame);
    defer gpa.free(tx);
    var link: gui_app.session_link.Link = undefined;
    link.open(session.transport(), rx, tx);
    link.close();
    var shell = gui_app.shell_loop.Shell.init(gpa, try gui_app.pane_layout.twoCore(gpa));
    defer shell.deinit();
    shell.link = &link;
    shell.server = shell_main.served(&session);
    var window = Headless.init(gpa, 480, 320);
    defer window.deinit();
    try std.testing.expectError(error.ImageNotLoaded, shell_main.drive(std.testing.io, &shell, window.platform(), image, "", 4));
}

test "a bad command line or an unreadable image never opens the window" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    Window.reset(null);
    const opener: platform.Opener = .{ .open = Window.open, .close = Window.close };
    try std.testing.expectEqual(@as(u8, 2), try shell_main.run(arena.allocator(), std.testing.io, &empty_env, &.{ "ra8_gui", image, "--instructions", "5" }, opener));
    try std.testing.expectEqual(@as(u8, 1), try shell_main.run(arena.allocator(), std.testing.io, &empty_env, &.{ "ra8_gui", "tests/fixtures/no-such.elf" }, opener));
    try std.testing.expectEqual(@as(u32, 0), Window.opens);
}

test "with no window to open the shell says 2 and loads nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    Window.reset(null);
    const code = try shell_main.run(arena.allocator(), std.testing.io, &empty_env, &.{ "ra8_gui", image }, .{ .open = Window.none, .close = Window.close });
    try std.testing.expectEqual(@as(u8, 2), code);
    try std.testing.expectEqual(@as(u32, 1), Window.opens);
    try std.testing.expectEqual(@as(u32, 0), Window.closes);
}
