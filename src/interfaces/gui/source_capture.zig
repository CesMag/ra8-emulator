//! Fills the source pane's snapshot and toggles its gutter breakpoints
//! through the session (RA8EMU-1080). The session keeps neither the image
//! nor where its sources live, so the shell hands in the line sections, the
//! image and the source directory. ui/source_pane.zig draws the result
//! without importing the session.
const std = @import("std");
const draw_list = @import("../render/draw_list.zig");
const elf = @import("ra8_board").image.elf;
const dwarf_line = @import("ra8_session").dwarf_line;
const session_api = @import("ra8_session").session_api;
const session_source = @import("ra8_session").session_source;
const source_pane = @import("ui/source_pane.zig");

comptime {
    std.debug.assert(session_api.BreakId == u32);
}

/// Reads `core`'s pc, finds its line in `sections`, and reads up to
/// `row_count` lines of that file from `dir`, the current one in the middle.
pub fn capture(session: *session_api.Session, core: session_api.Core, sections: dwarf_line.Sections, io: std.Io, dir: std.Io.Dir, row_count: usize) anyerror!source_pane.Snapshot {
    var snapshot: source_pane.Snapshot = .{ .pc = try session.register(core, .pc) };
    const place = (dwarf_line.lookup(sections, snapshot.pc) catch null) orelse return snapshot;
    var spelled: std.Io.Writer = .fixed(&snapshot.path_buf);
    session_source.path(&spelled, place.file) catch return snapshot;
    snapshot.path_len = spelled.buffered().len;
    snapshot.current = place.line;
    snapshot.state = .no_file;
    const file = dir.openFile(io, snapshot.path(), .{}) catch return snapshot;
    defer file.close(io);
    const wanted = @min(row_count, source_pane.max_rows);
    const half: u32 = @intCast(wanted / 2);
    const first = if (place.line > half) place.line - half else 1;
    var staging: [4096]u8 = undefined;
    var reader = file.reader(io, &staging);
    try readRows(&snapshot, &reader.interface, first, wanted);
    snapshot.state = .shown;
    return snapshot;
}

fn readRows(snapshot: *source_pane.Snapshot, reader: *std.Io.Reader, first: u32, wanted: usize) !void {
    var number: u32 = 1;
    while (snapshot.count < wanted) : (number += 1) {
        var row: source_pane.Row = .{ .number = number };
        var held: std.Io.Writer = .fixed(&row.buf);
        const ended = try session_source.takeLine(reader, &held);
        row.len = held.buffered().len;
        if (ended and row.len == 0) return;
        if (number >= first) {
            std.mem.replaceScalar(u8, row.buf[0..row.len], '\t', ' ');
            snapshot.rows[snapshot.count] = row;
            snapshot.count += 1;
        }
        if (ended) return;
    }
}

pub const Error = error{ NoCodeOnLine, TooManyMarks };

/// Clears the breakpoint the gutter set on `line` of `file`, or sets one
/// where the line table puts that line's code. True when one is now set.
pub fn toggle(marks: *source_pane.Marks, session: *session_api.Session, core: session_api.Core, image: ?elf.Image, file: []const u8, line: u32) anyerror!bool {
    if (marks.find(file, line)) |index| {
        try session.clearBreakpoint(core, marks.items[index].id);
        marks.items[index] = marks.items[marks.len - 1];
        marks.len -= 1;
        return false;
    }
    if (marks.len == source_pane.max_marks) return Error.TooManyMarks;
    const address = session_source.breakAt(image, .{ .file = file, .line = line }) orelse return Error.NoCodeOnLine;
    const id = try session.setBreakpoint(core, .{ .address = address });
    marks.items[marks.len] = .{ .file = std.hash.Fnv1a_64.hash(file), .line = line, .id = id };
    marks.len += 1;
    return true;
}

/// A gutter click: toggles that line's breakpoint, or null when the click
/// missed the gutter.
pub fn click(marks: *source_pane.Marks, session: *session_api.Session, core: session_api.Core, image: ?elf.Image, area: draw_list.Rect, snapshot: *const source_pane.Snapshot, x: i32, y: i32) anyerror!?bool {
    const line = source_pane.lineAt(area, snapshot, x, y) orelse return null;
    return try toggle(marks, session, core, image, snapshot.path(), line);
}
