//! Covers src/interfaces/gui/platform.zig: Text keeps the first bytes of the UTF-8 it
//! was given, show falls back to the CPU path unless the backend draws, a
//! backend with no appearance reports unknown, and one with no file picker
//! or title says so and is left alone.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const platform = gui_app.platform;
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const Text = platform.Text;

test "text keeps what it was given" {
    const text = Text.of("Hi!");
    try std.testing.expectEqualStrings("Hi!", text.slice());
}

test "text longer than its buffer keeps the first bytes" {
    const text = Text.of("0123456789");
    try std.testing.expectEqualStrings("01234567", text.slice());
}

const ShowStub = struct {
    answer: bool,
    shown: usize = 0,

    fn show(ctx: *anyopaque, list: *const draw_list.DrawList, atlas: ?raster.Atlas) anyerror!bool {
        _ = list;
        _ = atlas;
        const self: *ShowStub = @ptrCast(@alignCast(ctx));
        self.shown += 1;
        return self.answer;
    }
    fn poll(_: *anyopaque) ?platform.Event {
        return null;
    }
    fn size(_: *anyopaque) platform.Size {
        return .{ .width = 4, .height = 4 };
    }
    fn scale(_: *anyopaque) f32 {
        return 1;
    }
    fn present(_: *anyopaque, _: *const raster.Framebuffer) anyerror!void {}
};

test "a backend without a show path leaves drawing to the CPU" {
    var stub = ShowStub{ .answer = true };
    const window = platform.Platform{ .ctx = &stub, .vtable = &.{ .poll = ShowStub.poll, .size = ShowStub.size, .scale = ShowStub.scale, .present = ShowStub.present } };
    var list = draw_list.DrawList.init(std.testing.allocator, 4, 4);
    defer list.deinit();
    try std.testing.expect(!try window.show(&list, null));
    try std.testing.expectEqual(@as(usize, 0), stub.shown);
}

test "a backend's show answer decides whether the CPU path runs" {
    var list = draw_list.DrawList.init(std.testing.allocator, 4, 4);
    defer list.deinit();
    for ([_]bool{ true, false }) |answer| {
        var stub = ShowStub{ .answer = answer };
        const window = platform.Platform{ .ctx = &stub, .vtable = &.{ .poll = ShowStub.poll, .size = ShowStub.size, .scale = ShowStub.scale, .present = ShowStub.present, .show = ShowStub.show } };
        try std.testing.expectEqual(answer, try window.show(&list, null));
        try std.testing.expectEqual(@as(usize, 1), stub.shown);
    }
}

test "a backend with no appearance reports unknown" {
    const Stub = struct {
        fn poll(_: *anyopaque) ?platform.Event {
            return null;
        }
        fn size(_: *anyopaque) platform.Size {
            return .{ .width = 1, .height = 1 };
        }
        fn scale(_: *anyopaque) f32 {
            return 1.0;
        }
        fn present(_: *anyopaque, _: *const raster.Framebuffer) anyerror!void {}
    };
    var ctx: u8 = 0;
    const window: platform.Platform = .{ .ctx = &ctx, .vtable = &.{ .poll = Stub.poll, .size = Stub.size, .scale = Stub.scale, .present = Stub.present } };
    try std.testing.expectEqual(platform.Appearance.unknown, window.appearance());
}

test "a backend with no file picker puts none up, and one with no title takes none" {
    var stub = ShowStub{ .answer = false };
    const window = platform.Platform{ .ctx = &stub, .vtable = &.{ .poll = ShowStub.poll, .size = ShowStub.size, .scale = ShowStub.scale, .present = ShowStub.present } };
    try std.testing.expect(!window.openImage());
    window.title("ignored");
}

test "a key carries no shortcut modifier unless the backend says one was held" {
    const plain: platform.Event = .{ .key = .{ .code = 'o', .down = true } };
    try std.testing.expect(!plain.key.primary);
}
