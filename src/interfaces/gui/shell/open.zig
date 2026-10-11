//! Opening another image while the window is up (RA8EMU-959), the shell's
//! side of File > Open ELF. Cmd+O on macOS, Ctrl+O elsewhere, asks the
//! window for the OS's own file picker. The path it sends back is read here
//! and loaded into the session the way the first image was, so the board
//! comes back halted at the new image's reset vector. A file that cannot be
//! read, or is longer than a load carries, never reaches the session, and
//! one the session refuses leaves the image that was there as it was; either
//! way the status strip says so. The window's title names the image in use.
const std = @import("std");
const platform = @import("../platform.zig");
const status_bar = @import("../status/bar.zig");
const session_link = @import("../session_link.zig");

const Status = status_bar.Status;
const Link = session_link.Link;

/// SDLK_O.
pub const letter_o: u32 = 'o';
/// What follows the image's name in the window's title.
pub const title_tail = " - ra8 emulator";
/// Largest file read, as for the image on the command line.
pub const max_image: usize = 64 * 1024 * 1024;

pub const Open = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    /// The picker was asked for; the next frame puts it up.
    asked: bool = false,
    /// The image the window's title names.
    titled: ?status_bar.Image = null,

    /// Ask for the picker, as the menu's Open ELF item does.
    pub fn ask(self: *Open) void {
        self.asked = true;
    }

    /// The shortcut: the OS's modifier held with O. Returns whether the
    /// event was taken.
    pub fn key(self: *Open, event: platform.Event) bool {
        switch (event) {
            .key => |pressed| if (pressed.down and pressed.primary and pressed.code == letter_o) {
                self.ask();
                return true;
            },
            else => {},
        }
        return false;
    }

    /// Once a frame: put the picker up if it was asked for, and keep the
    /// window's title on the image in use.
    pub fn frame(self: *Open, window: platform.Platform, status: *const Status) void {
        if (self.asked) {
            self.asked = false;
            _ = window.openImage();
        }
        const image = status.image orelse return;
        if (self.titled) |shown| if (same(shown, image)) return;
        self.titled = image;
        var buf: [image.name_buf.len + title_tail.len]u8 = undefined;
        window.title(std.fmt.bufPrint(&buf, "{s}" ++ title_tail, .{image.name()}) catch return);
    }

    /// The path the picker sent back: read it and load it on the status
    /// bar's core. What goes wrong before the session is asked shows as a
    /// refusal on the status strip, and the session's own answer follows
    /// the load the usual way.
    pub fn picked(self: *Open, path: []const u8, link: *Link, status: *Status) void {
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(max_image)) catch {
            status.refused = .unread;
            return;
        };
        defer self.allocator.free(bytes);
        status.load(link, path, bytes) catch |err| {
            status.refused = if (err == error.ImageTooLarge) .too_large else .load;
        };
    }
};

fn same(a: status_bar.Image, b: status_bar.Image) bool {
    return std.mem.eql(u8, a.name(), b.name()) and std.mem.eql(u8, &a.hash, &b.hash);
}
