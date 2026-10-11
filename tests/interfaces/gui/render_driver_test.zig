const std = @import("std");
const gui = @import("gui_app");

const render_driver = gui.render_driver;

test "the order ends in software on every OS" {
    for ([_]std.Target.Os.Tag{ .linux, .macos, .windows, .freebsd }) |os| {
        try std.testing.expect(std.mem.endsWith(u8, render_driver.order(os), "software"));
    }
}

test "--render-driver replaces the order" {
    render_driver.override = "software";
    defer render_driver.override = null;
    try std.testing.expectEqualStrings("software", render_driver.hint(.linux));
    try std.testing.expectEqualStrings("software", render_driver.hint(.macos));
}

test "the first driver starting says nothing" {
    var chain: Fake = .{};
    const picked = render_driver.select(render_driver.order(.linux), &chain).?;
    try std.testing.expectEqualStrings("vulkan", picked.first);
    try std.testing.expectEqualStrings("vulkan", picked.chosen);
    var buf: [128]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), render_driver.note(picked, &buf));
}

test "a failed first driver starts on the next one and says so" {
    var chain: Fake = .{ .fail = 1 };
    const picked = render_driver.select(render_driver.order(.linux), &chain).?;
    try std.testing.expectEqualStrings("vulkan", picked.first);
    try std.testing.expectEqualStrings("opengl", picked.chosen);
    var buf: [128]u8 = undefined;
    const message = render_driver.note(picked, &buf).?;
    try std.testing.expect(std.mem.indexOf(u8, message, "vulkan") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "opengl") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "unavailable") != null);
}

test "the chain reaches software past repeated failures" {
    var chain: Fake = .{ .fail = 3 };
    const picked = render_driver.select(render_driver.order(.linux), &chain).?;
    try std.testing.expectEqualStrings("software", picked.chosen);
}

test "an empty list picks nothing" {
    var chain: Fake = .{};
    try std.testing.expectEqual(@as(?render_driver.Picked, null), render_driver.select("", &chain));
}

test "the status line names the driver and the GPU" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("render metal (GPU metal)", render_driver.status(&buf, "metal", "metal"));
    try std.testing.expectEqualStrings("render software", render_driver.status(&buf, "software", null));
}

const Fake = struct {
    fail: usize = 0,

    pub fn tryDriver(self: *Fake, name: []const u8) ?u8 {
        _ = name;
        if (self.fail > 0) {
            self.fail -= 1;
            return null;
        }
        return 1;
    }
};
