//! A platform with no window (RA8EMU-617): tests feed it input events and
//! read back the last frame it was asked to present.
const std = @import("std");
const platform_mod = @import("platform.zig");
const raster = @import("ra8_render").raster;
const Event = platform_mod.Event;
const Size = platform_mod.Size;

pub const Headless = struct {
    allocator: std.mem.Allocator,
    drawable: Size,
    dpi: f32 = 1.0,
    queue: std.ArrayListUnmanaged(Event) = .empty,
    next: usize = 0,
    /// A copy of the last presented frame.
    last: ?raster.Framebuffer = null,
    presents: u32 = 0,
    /// The OS appearance this window reports; tests set it.
    os: platform_mod.Appearance = .unknown,
    /// How many times the shell focused this window (RA8EMU-1156).
    focuses: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) Headless {
        return .{ .allocator = allocator, .drawable = .{ .width = width, .height = height } };
    }

    pub fn deinit(self: *Headless) void {
        self.queue.deinit(self.allocator);
        if (self.last) |*frame| frame.deinit(self.allocator);
    }

    /// Queue `event` as if the user had done it.
    pub fn feed(self: *Headless, event: Event) !void {
        try self.queue.append(self.allocator, event);
    }

    pub fn platform(self: *Headless) platform_mod.Platform {
        return .{ .ctx = self, .vtable = &.{ .poll = poll, .size = size, .scale = scale, .present = present, .appearance = appearance, .focus = focus } };
    }

    fn poll(ctx: *anyopaque) ?Event {
        const self: *Headless = @ptrCast(@alignCast(ctx));
        if (self.next == self.queue.items.len) {
            self.queue.clearRetainingCapacity();
            self.next = 0;
            return null;
        }
        const event = self.queue.items[self.next];
        self.next += 1;
        if (event == .resize) self.drawable = event.resize;
        return event;
    }

    fn size(ctx: *anyopaque) Size {
        const self: *Headless = @ptrCast(@alignCast(ctx));
        return self.drawable;
    }

    fn scale(ctx: *anyopaque) f32 {
        const self: *Headless = @ptrCast(@alignCast(ctx));
        return self.dpi;
    }

    fn appearance(ctx: *anyopaque) platform_mod.Appearance {
        const self: *Headless = @ptrCast(@alignCast(ctx));
        return self.os;
    }

    fn focus(ctx: *anyopaque) void {
        const self: *Headless = @ptrCast(@alignCast(ctx));
        self.focuses += 1;
    }

    fn present(ctx: *anyopaque, frame: *const raster.Framebuffer) anyerror!void {
        const self: *Headless = @ptrCast(@alignCast(ctx));
        if (self.last) |*old| {
            if (old.width != frame.width or old.height != frame.height) {
                old.deinit(self.allocator);
                self.last = null;
            }
        }
        if (self.last == null) self.last = try raster.Framebuffer.init(self.allocator, frame.width, frame.height);
        @memcpy(self.last.?.pixels, frame.pixels);
        self.presents += 1;
    }
};
