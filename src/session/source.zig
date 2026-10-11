//! What a session prints about source: the file and line an address
//! belongs to, read from the image's DWARF line table.
//!
//! The wording follows gdb's `info line` and `list`, so a transcript reads
//! the same either way. An image without line information, or a table this reader
//! refuses, answers the way gdb does for an address it has no line for.
const std = @import("std");
const elf = @import("ra8_board").image.elf;
const dwarf_line = @import("dwarf/line/line.zig");
const dwarf_line_find = @import("dwarf/line/find.zig");
const dwarf_info = @import("dwarf/info.zig");

pub const limits = struct {
    /// Lines `list` shows before the one it centres on.
    pub const before: u32 = 5;
    /// Lines `list` shows after it, so ten in all, as gdb shows.
    pub const after: u32 = 4;
    /// The longest source line printed whole; the rest of one is dropped.
    pub const line_bytes: usize = 1024;
};

/// The line sections of the session's image, empty when there is none.
pub fn of(image: ?elf.Image) dwarf_line.Sections {
    return if (image) |loaded| dwarf_line.ofImage(loaded) else .{};
}

/// `info line`: the line `address` belongs to and the addresses it covers.
pub fn line(out: anytype, sections: dwarf_line.Sections, address: u32) !void {
    const found = dwarf_line.lookup(sections, address) catch null;
    const place = found orelse {
        return out.print("No line number information available for address 0x{X:0>8}\n", .{address});
    };
    try out.print("Line {d} of \"", .{place.line});
    try path(out, place.file);
    try out.print("\" starts at address 0x{X:0>8} and ends at 0x{X:0>8}.\n", .{ place.address, place.end });
}

/// ` at FILE:LINE` for a backtrace frame, or nothing when the line table
/// does not cover `address`.
pub fn at(out: anytype, sections: dwarf_line.Sections, address: u32) !void {
    const found = dwarf_line.lookup(sections, address) catch null;
    const place = found orelse return;
    try out.print(" at ", .{});
    try path(out, place.file);
    try out.print(":{d}", .{place.line});
}

/// A file's name, under its directory unless the name is already absolute.
pub fn path(out: anytype, file: dwarf_line.File) !void {
    const absolute = std.mem.startsWith(u8, file.name, "/");
    if (file.directory.len != 0 and !absolute) try out.print("{s}/", .{file.directory});
    try out.print("{s}", .{file.name});
}

/// A place spelled FILE:LINE, as `break fw.zig:8` takes it.
pub const FileLine = struct {
    file: []const u8,
    line: u32,
};

/// FILE:LINE, or null when the text is some other kind of place.
pub fn fileLine(text: []const u8) ?FileLine {
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return null;
    if (colon == 0) return null;
    const number = std.fmt.parseInt(u32, text[colon + 1 ..], 10) catch return null;
    if (number == 0) return null;
    return .{ .file = text[0..colon], .line = number };
}

/// Where a break on FILE:LINE goes, or null when the line table has no
/// code there or after it in that file, or only in a function declared
/// after the line.
pub fn breakAt(image: ?elf.Image, want: FileLine) ?u32 {
    const sections = of(image);
    const found = (dwarf_line_find.addressOf(sections, want.file, want.line) catch null) orelse return null;
    const loaded = image orelse return found;
    const function = dwarf_info.containing(dwarf_info.ofImage(loaded), found) catch null;
    return settle(sections, found, function, want.line);
}

/// gdb's two rules for a line break that landed on a function's entry: a
/// line before the function's declaration is not in it, so there is no
/// break; otherwise the break moves past the prologue, to the row the line
/// table marks prologue_end.
pub fn settle(sections: dwarf_line.Sections, found: u32, function: ?dwarf_info.Function, asked: u32) ?u32 {
    const holder = function orelse return found;
    if (found != holder.low) return found;
    if (holder.decl_line > asked) return null;
    const past = dwarf_line_find.prologueEnd(sections, holder.low, holder.high) catch null;
    return past orelse found;
}

/// `list`: the ten source lines around the one `address` belongs to, read
/// from `dir` when the table's path is relative.
pub fn list(out: anytype, sections: dwarf_line.Sections, io: std.Io, dir: std.Io.Dir, address: u32) !void {
    const found = dwarf_line.lookup(sections, address) catch null;
    const place = found orelse {
        return out.print("No line number information available for address 0x{X:0>8}\n", .{address});
    };
    var name: [std.fs.max_path_bytes]u8 = undefined;
    var spelled: std.Io.Writer = .fixed(&name);
    path(&spelled, place.file) catch return missing(out, place);
    const file = dir.openFile(io, spelled.buffered(), .{}) catch return missing(out, place);
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const first = if (place.line > limits.before) place.line - limits.before else 1;
    try lines(out, &reader.interface, first, first + limits.before + limits.after);
}

fn missing(out: anytype, place: dwarf_line.Place) !void {
    try out.print("{d}\t", .{place.line});
    try path(out, place.file);
    try out.print(": No such file or directory.\n", .{});
}

/// Lines `first` through `last` of a source, numbered the way gdb numbers
/// them, stopping early when the source does.
pub fn lines(out: anytype, reader: *std.Io.Reader, first: u32, last: u32) !void {
    var number: u32 = 1;
    while (number <= last) : (number += 1) {
        var text: [limits.line_bytes]u8 = undefined;
        var held: std.Io.Writer = .fixed(&text);
        const ended = try takeLine(reader, &held);
        if (ended and held.buffered().len == 0) return;
        if (number >= first) try out.print("{d}\t{s}\n", .{ number, held.buffered() });
        if (ended) return;
    }
}

/// One line of `reader` into `held`, without its newline. A line longer
/// than `held` keeps its start and the rest is dropped. True once the
/// source has ended.
pub fn takeLine(reader: *std.Io.Reader, held: *std.Io.Writer) !bool {
    _ = reader.streamDelimiterLimit(held, '\n', .limited(held.buffer.len)) catch |err| switch (err) {
        error.StreamTooLong => {
            _ = reader.discardDelimiterInclusive('\n') catch |e| switch (e) {
                error.EndOfStream => return true,
                else => |other| return other,
            };
            return false;
        },
        else => |other| return other,
    };
    _ = reader.takeByte() catch |err| switch (err) {
        error.EndOfStream => return true,
        else => |other| return other,
    };
    return false;
}
