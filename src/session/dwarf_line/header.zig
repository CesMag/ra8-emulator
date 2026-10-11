//! A .debug_line unit's header (DWARF 2 to 5, 32-bit format) and the file
//! table inside it.
//!
//! Nothing is copied or allocated: the header keeps slices of the section,
//! and a file is found by walking its table each time it is asked for. A
//! lookup names one file, so the walk costs less than building an index.
//!
//! Versions 2 to 4 number files from one and directories from one, with
//! zero meaning the compilation directory. Version 5 numbers both from zero
//! and describes each entry with a list of (content, form) pairs.
const std = @import("std");
const dwarf_cursor = @import("../dwarf_cursor.zig");

const Cursor = dwarf_cursor.Cursor;
pub const Error = dwarf_cursor.Error;

/// The string sections a version 5 file table points into.
pub const Strings = struct {
    line_str: []const u8 = &.{},
    str: []const u8 = &.{},
};

pub const Header = struct {
    version: u16,
    min_instruction_length: u8,
    default_is_stmt: bool,
    line_base: i8,
    line_range: u8,
    opcode_base: u8,
    /// How many LEB128 operands each standard opcode takes, from opcode 1.
    standard_lengths: []const u8,
    /// The directory and file tables, as written.
    tables: []const u8,
    /// The line-number program the tables belong to.
    program: []const u8,
};

pub const Unit = struct {
    header: Header,
    /// The offset in .debug_line just past this unit.
    end: usize,
};

/// A source file: the directory it was named relative to, and its name.
/// Either may be empty when the table does not say.
pub const File = struct {
    directory: []const u8 = "",
    name: []const u8 = "",
};

const dwarf64_escape: u32 = 0xffff_fff0;

/// The unit that starts at `offset` in a .debug_line section.
pub fn read(section: []const u8, offset: usize) Error!Unit {
    var cursor = Cursor{ .bytes = section, .at = offset };
    const length = try cursor.int(u32);
    if (length >= dwarf64_escape) return Error.Unsupported;
    if (section.len - cursor.at < length) return Error.Truncated;
    const end = cursor.at + length;
    cursor.bytes = section[0..end];
    const version = try cursor.int(u16);
    if (version < 2 or version > 5) return Error.Unsupported;
    if (version >= 5) {
        if (try cursor.byte() != 4) return Error.Unsupported;
        _ = try cursor.byte();
    }
    const header_length = try cursor.int(u32);
    if (end - cursor.at < header_length) return Error.Truncated;
    const program_start = cursor.at + header_length;
    const min_instruction_length = try cursor.byte();
    // Maximum operations per instruction only matters to VLIW targets.
    if (version >= 4) _ = try cursor.byte();
    const default_is_stmt = try cursor.byte() != 0;
    const line_base: i8 = @bitCast(try cursor.byte());
    const line_range = try cursor.byte();
    const opcode_base = try cursor.byte();
    if (line_range == 0 or opcode_base == 0) return Error.Unsupported;
    const standard_lengths = try cursor.take(opcode_base - 1);
    if (cursor.at > program_start) return Error.Truncated;
    return .{ .end = end, .header = .{
        .version = version,
        .min_instruction_length = min_instruction_length,
        .default_is_stmt = default_is_stmt,
        .line_base = line_base,
        .line_range = line_range,
        .opcode_base = opcode_base,
        .standard_lengths = standard_lengths,
        .tables = section[cursor.at..program_start],
        .program = section[program_start..end],
    } };
}

/// File `index` as the line program numbers it, or an empty file when the
/// table has no such entry.
pub fn file(header: Header, index: u64, strings: Strings) Error!File {
    if (header.version >= 5) return fileV5(header.tables, index, strings);
    return fileV4(header.tables, index);
}

fn fileV4(tables: []const u8, index: u64) Error!File {
    var cursor = Cursor{ .bytes = tables };
    const directories = cursor.at;
    while ((try cursor.string()).len != 0) {}
    var number: u64 = 1;
    while (true) : (number += 1) {
        const name = try cursor.string();
        if (name.len == 0) return .{};
        const directory = try cursor.uleb();
        _ = try cursor.uleb();
        _ = try cursor.uleb();
        if (number == index) return .{ .directory = try directoryV4(tables[directories..], directory), .name = name };
    }
}

fn directoryV4(table: []const u8, index: u64) Error![]const u8 {
    var cursor = Cursor{ .bytes = table };
    var number: u64 = 1;
    while (index != 0) : (number += 1) {
        const name = try cursor.string();
        if (name.len == 0) break;
        if (number == index) return name;
    }
    return "";
}

fn fileV5(tables: []const u8, index: u64, strings: Strings) Error!File {
    var cursor = Cursor{ .bytes = tables };
    const directory_formats = try Formats.read(&cursor);
    const directory_count = try cursor.uleb();
    const directories = cursor.at;
    try skipEntries(&cursor, directory_formats, directory_count, strings);
    const file_formats = try Formats.read(&cursor);
    if (index >= try cursor.uleb()) return .{};
    try skipEntries(&cursor, file_formats, index, strings);
    const found = try file_formats.entry(&cursor, strings);
    var directory = File{ .name = found.path };
    if (found.directory < directory_count) {
        var at = Cursor{ .bytes = tables, .at = directories };
        try skipEntries(&at, directory_formats, found.directory, strings);
        directory.directory = (try directory_formats.entry(&at, strings)).path;
    }
    return directory;
}

fn skipEntries(cursor: *Cursor, formats: Formats, count: u64, strings: Strings) Error!void {
    var index: u64 = 0;
    while (index < count) : (index += 1) _ = try formats.entry(cursor, strings);
}

const content = struct {
    const path: u64 = 1;
    const directory_index: u64 = 2;
};

const form = struct {
    const block: u64 = 0x09;
    const data1: u64 = 0x0b;
    const data2: u64 = 0x05;
    const data4: u64 = 0x06;
    const data8: u64 = 0x07;
    const data16: u64 = 0x1e;
    const string: u64 = 0x08;
    const strp: u64 = 0x0e;
    const udata: u64 = 0x0f;
    const line_strp: u64 = 0x1f;
};

const Entry = struct {
    path: []const u8 = "",
    directory: u64 = 0,
};

/// A version 5 entry format: `count` (content, form) pairs.
const Formats = struct {
    pairs: []const u8,
    count: u8,

    fn read(cursor: *Cursor) Error!Formats {
        const count = try cursor.byte();
        const start = cursor.at;
        var index: u8 = 0;
        while (index < count) : (index += 1) {
            _ = try cursor.uleb();
            _ = try cursor.uleb();
        }
        return .{ .pairs = cursor.bytes[start..cursor.at], .count = count };
    }

    fn entry(self: Formats, cursor: *Cursor, strings: Strings) Error!Entry {
        var pairs = Cursor{ .bytes = self.pairs };
        var found = Entry{};
        var index: u8 = 0;
        while (index < self.count) : (index += 1) {
            const kind = try pairs.uleb();
            const value = try readForm(cursor, try pairs.uleb(), strings);
            switch (value) {
                .text => |text| if (kind == content.path) {
                    found.path = text;
                },
                .number => |number| if (kind == content.directory_index) {
                    found.directory = number;
                },
            }
        }
        return found;
    }
};

const Value = union(enum) { text: []const u8, number: u64 };

fn readForm(cursor: *Cursor, kind: u64, strings: Strings) Error!Value {
    return switch (kind) {
        form.string => .{ .text = try cursor.string() },
        form.line_strp => .{ .text = try dwarf_cursor.stringAt(strings.line_str, try cursor.int(u32)) },
        form.strp => .{ .text = try dwarf_cursor.stringAt(strings.str, try cursor.int(u32)) },
        form.udata => .{ .number = try cursor.uleb() },
        form.data1 => .{ .number = try cursor.byte() },
        form.data2 => .{ .number = try cursor.int(u16) },
        form.data4 => .{ .number = try cursor.int(u32) },
        form.data8 => .{ .number = try cursor.int(u64) },
        form.data16 => blk: {
            try cursor.skip(16);
            break :blk .{ .number = 0 };
        },
        form.block => blk: {
            try cursor.skip(try cursor.uleb());
            break :blk .{ .number = 0 };
        },
        else => Error.Unsupported,
    };
}
