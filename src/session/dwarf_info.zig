//! Function bounds from .debug_info: each DW_TAG_subprogram's low_pc,
//! high_pc and decl_line.
//!
//! A break on FILE:LINE needs them to act the way gdb does. A line with no
//! code of its own falls through to the next line that has some, but not
//! into a function declared after the asked line, and a break on a
//! function's first line lands past its prologue. Only those three
//! attributes are read; every other attribute is skipped by its form.
//!
//! 32-bit DWARF 2 to 5 with 4-byte addresses. A function whose low_pc
//! goes through .debug_addr (DW_FORM_addrx) or that only has DW_AT_ranges
//! is left out.
const std = @import("std");
const elf = @import("ra8_board").image.elf;
const dwarf_cursor = @import("dwarf_cursor.zig");
const dwarf_line = @import("dwarf_line/dwarf_line.zig");

const Cursor = dwarf_cursor.Cursor;
pub const Error = dwarf_cursor.Error;

pub const Sections = struct {
    info: []const u8 = &.{},
    abbrev: []const u8 = &.{},
};

/// One function: the addresses [low, high) and the line it is declared on
/// (0 when the DIE does not say).
pub const Function = struct {
    low: u32,
    high: u32,
    decl_line: u32,
};

pub const tag_subprogram: u64 = 0x2e;

pub const attribute = struct {
    pub const low_pc: u64 = 0x11;
    pub const high_pc: u64 = 0x12;
    pub const decl_line: u64 = 0x3b;
};

pub const form = struct {
    pub const addr: u64 = 0x01;
    pub const data2: u64 = 0x05;
    pub const data4: u64 = 0x06;
    pub const data8: u64 = 0x07;
    pub const data1: u64 = 0x0b;
    pub const sdata: u64 = 0x0d;
    pub const udata: u64 = 0x0f;
    pub const indirect: u64 = 0x16;
    pub const implicit_const: u64 = 0x21;
};

/// The info sections of an image, empty when it has none.
pub fn ofImage(image: elf.Image) Sections {
    return .{ .info = dwarf_line.section(image, ".debug_info"), .abbrev = dwarf_line.section(image, ".debug_abbrev") };
}

/// The innermost function whose [low, high) covers `address`.
pub fn containing(sections: Sections, address: u32) Error!?Function {
    var best: ?Function = null;
    var offset: usize = 0;
    while (offset < sections.info.len) {
        var cursor = Cursor{ .bytes = sections.info, .at = offset };
        const length = try cursor.int(u32);
        if (length >= 0xFFFF_FFF0) return Error.Unsupported;
        const end = cursor.at + length;
        if (end > sections.info.len) return Error.Truncated;
        cursor.bytes = sections.info[0..end];
        if (try header(&cursor, sections.abbrev)) |abbrev| try scan(&cursor, abbrev, address, &best);
        offset = end;
    }
    return best;
}

/// A unit's header, leaving `cursor` on its first DIE. Returns the unit's
/// abbreviation table, or null for a unit kind with no code in it.
fn header(cursor: *Cursor, abbrev: []const u8) Error!?[]const u8 {
    const version = try cursor.int(u16);
    var table: u32 = 0;
    var address_size: u8 = 0;
    var kind: u8 = 1;
    switch (version) {
        2, 3, 4 => {
            table = try cursor.int(u32);
            address_size = try cursor.byte();
        },
        5 => {
            kind = try cursor.byte();
            address_size = try cursor.byte();
            table = try cursor.int(u32);
        },
        else => return Error.Unsupported,
    }
    // DW_UT_compile and DW_UT_partial; type and split units hold no code here.
    if (kind != 1 and kind != 3) return null;
    if (address_size != 4) return Error.Unsupported;
    if (table > abbrev.len) return Error.Truncated;
    return abbrev[table..];
}

fn scan(cursor: *Cursor, abbrev: []const u8, address: u32, best: *?Function) Error!void {
    while (!cursor.done()) {
        const code = try cursor.uleb();
        if (code == 0) continue;
        var spec = try find(abbrev, code);
        var found = Found{};
        while (true) {
            const name = try spec.cursor.uleb();
            const kind = try spec.cursor.uleb();
            if (name == 0 and kind == 0) break;
            const implicit: i64 = if (kind == form.implicit_const) try spec.cursor.sleb() else 0;
            const value = try read(cursor, kind, implicit);
            if (spec.tag == tag_subprogram) found.take(name, value);
        }
        const function = found.function() orelse continue;
        if (address < function.low or address >= function.high) continue;
        if (best.*) |held| if (function.high - function.low >= held.high - held.low) continue;
        best.* = function;
    }
}

const Spec = struct { tag: u64, cursor: Cursor };

/// The abbreviation `code`, its cursor on the first attribute spec.
fn find(abbrev: []const u8, code: u64) Error!Spec {
    var cursor = Cursor{ .bytes = abbrev };
    while (true) {
        const at = try cursor.uleb();
        if (at == 0) return Error.Unsupported;
        const tag = try cursor.uleb();
        _ = try cursor.byte();
        if (at == code) return .{ .tag = tag, .cursor = cursor };
        while (true) {
            const name = try cursor.uleb();
            const kind = try cursor.uleb();
            if (name == 0 and kind == 0) break;
            if (kind == form.implicit_const) _ = try cursor.sleb();
        }
    }
}

const Value = struct { number: u64, address: bool = false };

/// An attribute's value when its form is an address or a constant, else
/// null once the cursor is past it.
fn read(cursor: *Cursor, kind: u64, implicit: i64) Error!?Value {
    return switch (kind) {
        form.addr => .{ .number = try cursor.int(u32), .address = true },
        form.data1 => .{ .number = try cursor.byte() },
        form.data2 => .{ .number = try cursor.int(u16) },
        form.data4 => .{ .number = try cursor.int(u32) },
        form.data8 => .{ .number = try cursor.int(u64) },
        form.udata => .{ .number = try cursor.uleb() },
        form.sdata => .{ .number = @bitCast(try cursor.sleb()) },
        form.implicit_const => .{ .number = @bitCast(implicit) },
        form.indirect => read(cursor, try cursor.uleb(), implicit),
        else => {
            try skip(cursor, kind);
            return null;
        },
    };
}

/// Step over a value whose form gives nothing this reader needs.
fn skip(cursor: *Cursor, kind: u64) Error!void {
    const fixed: ?u64 = switch (kind) {
        0x19 => 0,
        0x0c, 0x11, 0x25, 0x29 => 1,
        0x12, 0x26, 0x2a => 2,
        0x27, 0x2b => 3,
        0x0e, 0x10, 0x13, 0x17, 0x1c, 0x1d, 0x1f, 0x28, 0x2c => 4,
        0x14, 0x20, 0x24 => 8,
        0x1e => 16,
        else => null,
    };
    if (fixed) |count| return cursor.skip(count);
    const count: u64 = switch (kind) {
        0x08 => {
            _ = try cursor.string();
            return;
        },
        0x15, 0x1a, 0x1b, 0x22, 0x23 => {
            _ = try cursor.uleb();
            return;
        },
        0x0a => try cursor.byte(),
        0x03 => try cursor.int(u16),
        0x04 => try cursor.int(u32),
        0x09, 0x18 => try cursor.uleb(),
        else => return Error.Unsupported,
    };
    try cursor.skip(count);
}

/// What a subprogram DIE said, gathered attribute by attribute.
const Found = struct {
    low: ?u64 = null,
    high: ?Value = null,
    line: u64 = 0,

    fn take(self: *Found, name: u64, value: ?Value) void {
        const seen = value orelse return;
        if (name == attribute.low_pc and seen.address) self.low = seen.number;
        if (name == attribute.high_pc) self.high = seen;
        if (name == attribute.decl_line) self.line = seen.number;
    }

    /// The function, when both ends are known. A constant high_pc is a
    /// length from low_pc (DWARF 4 on), an address one is the end itself.
    fn function(self: Found) ?Function {
        const low = self.low orelse return null;
        const high = self.high orelse return null;
        const end = if (high.address) high.number else low +| high.number;
        if (end <= low or end > std.math.maxInt(u32)) return null;
        return .{ .low = @intCast(low), .high = @intCast(end), .decl_line = std.math.cast(u32, self.line) orelse 0 };
    }
};
