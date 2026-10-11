//! The OS's own file picker for a firmware image (RA8EMU-959), through
//! SDL_ShowOpenFileDialog: Finder's panel on macOS, Explorer's on Windows,
//! the desktop portal (or zenity) on Linux. SDL answers through a callback
//! that may run on another thread, so the callback only copies the path and
//! posts it to the window's own event queue; `take` hands it to the poll
//! loop, which sends it on as a platform event.
const std = @import("std");
const c = @import("c.zig").c;

const filters = [_]c.SDL_DialogFileFilter{
    .{ .name = "Firmware images", .pattern = "elf;axf" },
    .{ .name = "All files", .pattern = "*" },
};

pub const Picker = struct {
    /// The SDL event type a choice comes back as; 0 when SDL had none left
    /// to give, and the picker never goes up.
    kind: u32,
    /// The last path chosen, kept until the next one.
    path: ?[*:0]u8 = null,

    pub fn init() Picker {
        return .{ .kind = c.SDL_RegisterEvents(1) };
    }

    pub fn deinit(self: *Picker) void {
        if (self.path) |held| c.SDL_free(held);
        self.path = null;
    }

    /// Put the picker up over `window`. It does not wait: a choice arrives
    /// later as an event of `kind`, and a cancel as nothing.
    pub fn show(self: *const Picker, window: *c.SDL_Window) void {
        if (self.kind == 0) return;
        c.SDL_ShowOpenFileDialog(chosen, @ptrFromInt(self.kind), window, &filters, filters.len, null, false);
    }

    /// The path `ev` carries when it is a choice from the picker. It holds
    /// until the next choice is taken.
    pub fn take(self: *Picker, ev: *const c.SDL_Event) ?[]const u8 {
        if (self.kind == 0 or ev.type != self.kind) return null;
        const path: [*:0]u8 = @ptrCast(ev.user.data1 orelse return null);
        self.deinit();
        self.path = path;
        return std.mem.span(path);
    }
};

/// SDL's answer, on whatever thread it likes: no list for an error, an empty
/// one for a cancel, else the one file chosen. `userdata` is the event type.
pub fn chosen(userdata: ?*anyopaque, list: [*c]const [*c]const u8, _: c_int) callconv(.c) void {
    if (list == null or list[0] == null) return;
    const copy = c.SDL_strdup(list[0]) orelse return;
    var ev = std.mem.zeroes(c.SDL_Event);
    ev.user.type = @intCast(@intFromPtr(userdata));
    ev.user.data1 = copy;
    if (!c.SDL_PushEvent(&ev)) c.SDL_free(copy);
}
