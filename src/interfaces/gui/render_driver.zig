//! The render-driver fallback chain (RA8EMU-226): ra8_gui asks SDL for
//! render drivers in a preference order per OS and takes the first that
//! starts, down to software, instead of dying on a broken driver. The
//! SDL backend (sdl.zig) runs the chain through `select` and reports
//! what started in `active` and `gpu`; this file holds the order, the
//! choice and the status text, and never imports SDL.

const std = @import("std");

/// The driver preference order per OS, software always last: SDL's own
/// defaults, so a broken hardware driver falls through to the next one.
pub fn order(os: std.Target.Os.Tag) []const u8 {
    return switch (os) {
        .windows => "direct3d12,direct3d11,vulkan,opengl,software",
        .macos => "metal,vulkan,opengl,software",
        .linux => "vulkan,opengl,opengles2,software",
        else => "opengl,opengles2,software",
    };
}

/// `--render-driver NAME` (RA8EMU-226): the only driver tried.
pub var override: ?[]const u8 = null;

/// What the backend reports after the chain ran: the driver that started
/// and the GPU device's driver, when the renderer has one.
pub var active: []const u8 = "";
pub var gpu: ?[]const u8 = null;

/// The list the backend tries: the override, else the order for this OS.
pub fn hint(os: std.Target.Os.Tag) []const u8 {
    return override orelse order(os);
}

/// What the chain picked: `first` is the first candidate tried, `chosen`
/// the one that started.
pub const Picked = struct {
    first: []const u8,
    chosen: []const u8,
};

/// Walk the comma list, taking the first driver `ctx.tryDriver` starts.
/// The winner's handle stays in the context. Null when none start, which
/// the backend turns into its error.
pub fn select(comma: []const u8, ctx: anytype) ?Picked {
    var first: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, comma, ',');
    while (it.next()) |name| {
        const candidate = std.mem.trim(u8, name, " ");
        if (candidate.len == 0) continue;
        if (ctx.tryDriver(candidate) != null) {
            return .{ .first = first orelse candidate, .chosen = candidate };
        }
        if (first == null) first = candidate;
    }
    return null;
}

/// What the chain owes the console when the first driver failed: the
/// first choice and the driver that actually started. Null when the
/// first one started.
pub fn note(picked: Picked, buf: []u8) ?[]const u8 {
    if (std.mem.eql(u8, picked.first, picked.chosen)) return null;
    var stream: std.Io.Writer = .fixed(buf);
    stream.print("first render driver {s} unavailable, started on {s}", .{ picked.first, picked.chosen }) catch return null;
    return stream.buffered();
}

/// The status bar's render segment: the driver and the GPU's driver.
pub fn status(buf: []u8, renderer: []const u8, device: ?[]const u8) []const u8 {
    var stream: std.Io.Writer = .fixed(buf);
    if (device) |d| {
        stream.print("render {s} (GPU {s})", .{ renderer, d }) catch {};
    } else {
        stream.print("render {s}", .{renderer}) catch {};
    }
    return stream.buffered();
}
