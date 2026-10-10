//! Tests for src/interfaces/gui/shell_startup.zig and the shell flags that
//! fill it (RA8EMU-1095): the window's `--attach`, `--click`,
//! `--camera-source` and `--window-stills` reach the shell, and the queued
//! plugs reach an in-process session once its image is loaded.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");

const shell_main = gui_app.shell_main;
const shell_startup = gui_app.shell_startup;
const local_session = gui_app.local_session;
const shell_loop = gui_app.shell_loop;
const shell_devices = gui_app.shell_devices;
const session_link = gui_app.session_link;
const platform = gui_app.platform;
const Headless = gui_app.headless.Headless;
const Env = ra8.rpc.session_rpc.Client.Env;

const image = "tests/fixtures/fpu/fp_basic.elf";

test "the click parts are ones the catalog takes" {
    var startup: shell_startup.Startup = .{};
    try startup.addClick();
    try std.testing.expectEqual(@as(usize, 2), startup.count);
    try std.testing.expect(startup.pending());
}

test "an unknown model is refused before the window opens" {
    var startup: shell_startup.Startup = .{};
    try std.testing.expectError(error.UnknownModel, startup.add("nope@i2c:touch@0x40"));
    try std.testing.expectEqual(@as(usize, 0), startup.count);
    try std.testing.expect(!startup.pending());
}

test "more plugs than a run may fit are refused" {
    var startup: shell_startup.Startup = .{};
    for (0..shell_startup.max_plugs) |_| try startup.add(shell_startup.click_plugs[0]);
    try std.testing.expectError(error.TooManyPlugs, startup.add(shell_startup.click_plugs[1]));
}

test "the window's startup flags are kept around the image" {
    const args = try shell_main.parse(&.{ "ra8_gui", "shell", "--click", "--attach", "max17048@i2c:touch@0x37", "app.elf", "--camera-source", "gradient", "--window-stills", "/tmp/stills", "--window-stills-every", "3" });
    try std.testing.expectEqualStrings("app.elf", args.image);
    try std.testing.expectEqual(@as(usize, 3), args.startup.count);
    try std.testing.expectEqualStrings("max17048@i2c:touch@0x37", args.startup.plugs[2]);
    try std.testing.expectEqual(true, args.camera.?.kind == .gradient);
    try std.testing.expectEqualStrings("/tmp/stills", args.stills.?);
    try std.testing.expectEqual(@as(u32, 3), args.stills_every);
}

test "a bad attach, camera source or stills count is a usage error" {
    try std.testing.expectError(error.Usage, shell_main.parse(&.{ "ra8_gui", "shell", "--attach", "nope@x", "app.elf" }));
    try std.testing.expectError(error.Usage, shell_main.parse(&.{ "ra8_gui", "shell", "--camera-source", "nope", "app.elf" }));
    try std.testing.expectError(error.Usage, shell_main.parse(&.{ "ra8_gui", "shell", "--window-stills-every", "0", "app.elf" }));
    try std.testing.expectError(error.Usage, shell_main.parse(&.{ "ra8_gui", "shell", "app.elf", "--attach" }));
}

/// A headless window that asks to close once every startup plug is
/// answered and the device list has been read again after the last one.
const Settled = struct {
    inner: *Headless,
    startup: *const shell_startup.Startup,
    devices: *const shell_devices.Devices,
    frames: u32 = 0,
    asked_to_close: bool = false,

    fn window(self: *Settled) platform.Platform {
        return .{ .ctx = self, .vtable = &.{ .poll = poll, .size = size, .scale = scale, .present = present } };
    }

    fn done(self: *const Settled) bool {
        return !self.startup.pending() and !self.devices.want and self.devices.asked == null;
    }

    fn poll(ctx: *anyopaque) ?platform.Event {
        const self: *Settled = @ptrCast(@alignCast(ctx));
        if (self.asked_to_close or !(self.done() or self.frames > 2000)) return self.inner.platform().poll();
        self.asked_to_close = true;
        return .quit;
    }

    fn size(ctx: *anyopaque) platform.Size {
        const self: *Settled = @ptrCast(@alignCast(ctx));
        return self.inner.platform().size();
    }

    fn scale(ctx: *anyopaque) f32 {
        const self: *Settled = @ptrCast(@alignCast(ctx));
        return self.inner.platform().scale();
    }

    fn present(ctx: *anyopaque, frame: *const ra8.render.raster.Framebuffer) anyerror!void {
        const self: *Settled = @ptrCast(@alignCast(ctx));
        self.frames += 1;
        return self.inner.platform().present(frame);
    }
};

/// Run the shell on an in-process session of `image` until `startup` has
/// sent everything, as ra8_gui does, and leave the list in `devices`.
fn settle(startup: *shell_startup.Startup, devices: *shell_devices.Devices) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var session: local_session.LocalSession = undefined;
    try session.open(gpa, io, image);
    defer session.deinit();
    const rx = try gpa.alloc(u8, 2 * Env.max_frame);
    defer gpa.free(rx);
    const tx = try gpa.alloc(u8, Env.max_frame);
    defer gpa.free(tx);
    var link: session_link.Link = undefined;
    link.open(session.transport(), rx, tx);
    var shell = shell_loop.Shell.init(gpa, try gui_app.pane_layout.twoCore(gpa));
    defer shell.deinit();
    shell.link = &link;
    shell.server = shell_main.served(&session);
    shell.devices = devices;
    shell.startup = startup;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, image, gpa, .limited(1 << 20));
    defer gpa.free(bytes);
    var headless = Headless.init(gpa, 480, 320);
    defer headless.deinit();
    var settled = Settled{ .inner = &headless, .startup = startup, .devices = devices };
    try shell_main.drive(io, &shell, settled.window(), image, bytes, null);
    try std.testing.expect(settled.done());
}

fn listed(devices: *const shell_devices.Devices, wanted: []const u8) bool {
    var lines = devices.lines();
    while (lines.next()) |line| if (std.mem.eql(u8, line, wanted)) return true;
    return false;
}

test "the startup plugs are fitted once the image is loaded, and the list shows them" {
    var startup: shell_startup.Startup = .{};
    try startup.addClick();
    var devices: shell_devices.Devices = .{};
    try settle(&startup, &devices);
    try std.testing.expectEqual(@as(usize, 0), startup.refused);
    for (shell_startup.click_plugs) |plug| try std.testing.expect(listed(&devices, plug));
}

test "a plug the session refuses is counted and the rest still go" {
    var startup: shell_startup.Startup = .{};
    try startup.add(shell_startup.click_plugs[1]);
    try startup.add(shell_startup.click_plugs[1]);
    try startup.add(shell_startup.click_plugs[0]);
    var devices: shell_devices.Devices = .{};
    try settle(&startup, &devices);
    try std.testing.expectEqual(@as(usize, 1), startup.refused);
    for (shell_startup.click_plugs) |plug| try std.testing.expect(listed(&devices, plug));
}
