//! A flame graph click opens the clicked frame's function (RA8EMU-837).
//! The frame's name resolves to its sized ELF symbol, and the function's
//! first instruction to a line through the same line table the source pane
//! reads. With a line, the source pane opens there with that line current.
//! With no line (no debug info, or a ROM or vendor blob), the disassembly
//! pane opens at the function's start and a one-line status says why. The
//! shell (RA8EMU-201) routes the result to its panes; the session's
//! disassembly capture fills the fallback from `Opened.disasm`.
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const Image = @import("ra8_session").symbols.Image;
const symbols = @import("ra8_session").symbols;
const dwarf_line = @import("ra8_session").dwarf.line;
const flame_model = @import("model.zig");
const flame_pane = @import("../ui/flame_pane.zig");
const source_capture = @import("../source_capture.zig");
const source_pane = @import("../ui/source_pane.zig");

/// The most a status line holds.
pub const status_cap: usize = 160;

/// Where a frame's function resolved.
pub const Target = union(enum) {
    /// The function's first instruction and the line it sits on.
    source: struct { address: u32, place: dwarf_line.Place },
    /// No line covers the function's first instruction, at this address.
    disasm: u32,
    /// The image names no sized function by that name (or it is the root).
    missing,
};

/// Resolve function `name` in `image` and its line sections.
pub fn resolve(image: Image, sections: dwarf_line.Sections, name: []const u8) Target {
    const extent = symbols.extentOf(image, name) orelse return .missing;
    const place = (dwarf_line.lookup(sections, extent.address) catch null) orelse return .{ .disasm = extent.address };
    return .{ .source = .{ .address = extent.address, .place = place } };
}

/// What a click opened: the source pane, or the disassembly pane at an
/// address with a status line saying why, or nothing with a status line.
pub const Opened = struct {
    source: ?source_pane.Snapshot = null,
    disasm: ?u32 = null,
    status_buf: [status_cap]u8 = undefined,
    status_len: usize = 0,

    pub fn status(self: *const Opened) []const u8 {
        return self.status_buf[0..self.status_len];
    }

    fn say(self: *Opened, comptime format: []const u8, args: anytype) void {
        const said = std.fmt.bufPrint(&self.status_buf, format, args) catch self.status_buf[0..];
        self.status_len = said.len;
    }
};

/// Open function `name`: read `row_count` source rows from `dir`, or fall
/// back to disassembly with a status line.
pub fn open(image: Image, sections: dwarf_line.Sections, name: []const u8, io: std.Io, dir: std.Io.Dir, row_count: usize) anyerror!Opened {
    var opened: Opened = .{};
    switch (resolve(image, sections, name)) {
        .source => |found| opened.source = try source_capture.captureAt(found.address, found.place, io, dir, row_count),
        .disasm => |address| {
            opened.disasm = address;
            opened.say("{s} has no line info; disassembly at {X:0>8}", .{ name, address });
        },
        .missing => opened.say("{s} is not a sized function in the image", .{name}),
    }
    return opened;
}

/// A click at (x, y) on the flame pane: opens the frame under it, or null
/// for an empty spot or the root box.
pub fn click(area: draw_list.Rect, model: *const flame_model.Model, x: i32, y: i32, image: Image, sections: dwarf_line.Sections, io: std.Io, dir: std.Io.Dir, row_count: usize) anyerror!?Opened {
    const node = flame_pane.nodeAt(area, model, x, y) orelse return null;
    if (node == 0) return null;
    return try open(image, sections, model.name(node), io, dir, row_count);
}
