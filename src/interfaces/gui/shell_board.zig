//! The shell's board feed (RA8EMU-790): the panel image the session streams
//! as lcd_dirty rectangles of grayscale pixels (RA8EMU-789). Once the link is
//! connected it subscribes cpu0's lcd_dirty; each rectangle is copied into
//! an RGBA image that grows to cover every rectangle seen, and pixels no
//! rectangle has reached yet stay black.
const std = @import("std");
const proto = @import("ra8_rpc").session_rpc;
const session_link = @import("session_link.zig");
const draw_list = @import("ra8_render").draw_list;
const colors = @import("ui/colors.zig");

const Color = draw_list.Color;
const unseen = colors.black;

pub const Board = struct {
    allocator: std.mem.Allocator,
    pixels: []Color = &.{},
    width: u32 = 0,
    height: u32 = 0,
    subscribed: bool = false,

    pub fn init(allocator: std.mem.Allocator) Board {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Board) void {
        self.allocator.free(self.pixels);
    }

    /// Subscribe cpu0's panel changes, once, after the session greets.
    pub fn attach(self: *Board, link: *session_link.Link) void {
        if (self.subscribed or link.state != .connected) return;
        _ = link.send(proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = .lcd_dirty }) catch return;
        self.subscribed = true;
    }

    /// Copy an lcd_dirty rectangle into the image.
    pub fn observe(self: *Board, arrival: session_link.Arrival) error{OutOfMemory}!void {
        const event = switch (arrival) {
            .event => |event| event,
            .response => return,
        };
        if (event.topic != @backingInt(proto.Topic.lcd_dirty)) return;
        const rect = proto.decode(proto.DirtyRect, event.payload) catch return;
        if (rect.core != .cpu0 or rect.pixels.len != @as(usize, rect.width) * rect.height) return;
        try self.cover(@as(u32, rect.x) + rect.width, @as(u32, rect.y) + rect.height);
        for (0..rect.height) |row| {
            const into = self.pixels[(rect.y + row) * self.width + rect.x ..][0..rect.width];
            for (into, rect.pixels[row * rect.width ..][0..rect.width]) |*pixel, gray| pixel.* = Color.rgb(gray, gray, gray);
        }
    }

    /// Whether any rectangle has arrived yet.
    pub fn hasFrame(self: *const Board) bool {
        return self.width != 0 and self.height != 0;
    }

    pub fn image(self: *const Board) draw_list.Image {
        return .{ .width = self.width, .height = self.height, .pixels = self.pixels };
    }

    /// Grow the image to at least `width` by `height`, keeping what it holds.
    fn cover(self: *Board, width: u32, height: u32) error{OutOfMemory}!void {
        if (width <= self.width and height <= self.height) return;
        const wide = @max(width, self.width);
        const tall = @max(height, self.height);
        const grown = try self.allocator.alloc(Color, @as(usize, wide) * tall);
        @memset(grown, unseen);
        for (0..self.height) |row| {
            @memcpy(grown[row * wide ..][0..self.width], self.pixels[row * self.width ..][0..self.width]);
        }
        self.allocator.free(self.pixels);
        self.pixels = grown;
        self.width = wide;
        self.height = tall;
    }
};
