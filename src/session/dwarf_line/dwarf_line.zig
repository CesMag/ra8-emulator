//! Source lines from DWARF .debug_line: which file and line an address
//! belongs to.
//!
//! The line-number program is run as written, row by row, with no table
//! built: an address belongs to the last row at or below it whose sequence
//! carries on past it. A lookup walks every unit until one answers, which
//! is quick next to the stop that asked for it.
const std = @import("std");
const elf = @import("ra8_board").image.elf;
const symbols = @import("../symbols.zig");
const dwarf_cursor = @import("../dwarf_cursor.zig");
const line_header = @import("header.zig");

const Cursor = dwarf_cursor.Cursor;
pub const Error = dwarf_cursor.Error;
pub const File = line_header.File;
pub const Header = line_header.Header;

/// The sections a lookup reads. Any may be empty.
pub const Sections = struct {
    line: []const u8 = &.{},
    strings: line_header.Strings = .{},
};

/// Where an address's source line is, and the addresses its row covers.
pub const Place = struct {
    file: File,
    line: u32,
    address: u32,
    /// The first address past the row: where the next row starts.
    end: u32,
};

/// One row of the line table.
pub const Row = struct {
    address: u32,
    file: u64,
    line: u32,
    /// The first address past a sequence, not an instruction of its own.
    end_sequence: bool = false,
    /// DW_LNS_set_prologue_end came before this row: the function's
    /// prologue is done at this address.
    prologue_end: bool = false,
};

/// The line-number state machine, emitting one row per `next`.
pub const Rows = struct {
    header: Header,
    cursor: Cursor,
    state: Row,

    pub fn init(header: Header) Rows {
        return .{ .header = header, .cursor = .{ .bytes = header.program }, .state = start() };
    }

    fn start() Row {
        return .{ .address = 0, .file = 1, .line = 1 };
    }

    pub fn next(self: *Rows) Error!?Row {
        while (!self.cursor.done()) {
            const opcode = try self.cursor.byte();
            if (opcode >= self.header.opcode_base) return self.special(opcode);
            const row = if (opcode == 0) try self.extended() else try self.standard(opcode);
            if (row) |emitted| return emitted;
        }
        return null;
    }

    fn special(self: *Rows, opcode: u8) Row {
        const adjusted = opcode - self.header.opcode_base;
        self.advance(adjusted / self.header.line_range);
        self.addLine(@as(i64, self.header.line_base) + adjusted % self.header.line_range);
        return self.emit();
    }

    /// The current row, clearing the flags DWARF resets after each row.
    fn emit(self: *Rows) Row {
        const row = self.state;
        self.state.prologue_end = false;
        return row;
    }

    fn extended(self: *Rows) Error!?Row {
        const body = try self.cursor.take(std.math.cast(usize, try self.cursor.uleb()) orelse return Error.Truncated);
        if (body.len == 0) return null;
        var operands = Cursor{ .bytes = body[1..] };
        switch (body[0]) {
            0x01 => {
                var row = self.state;
                row.end_sequence = true;
                self.state = start();
                return row;
            },
            0x02 => self.state.address = if (operands.bytes.len >= 8) @truncate(try operands.int(u64)) else try operands.int(u32),
            // define_file, set_discriminator and vendor opcodes change no row.
            else => {},
        }
        return null;
    }

    fn standard(self: *Rows, opcode: u8) Error!?Row {
        switch (opcode) {
            0x01 => return self.emit(),
            0x02 => self.advance(try self.cursor.uleb()),
            0x03 => self.addLine(try self.cursor.sleb()),
            0x04 => self.state.file = try self.cursor.uleb(),
            0x08 => self.advance((255 - self.header.opcode_base) / self.header.line_range),
            0x09 => self.state.address +%= try self.cursor.int(u16),
            0x0a => self.state.prologue_end = true,
            // is_stmt, basic_block and epilogue_begin take no
            // operand; column and isa take one. None of them moves a row.
            else => {
                var operands = self.header.standard_lengths[opcode - 1];
                while (operands > 0) : (operands -= 1) _ = try self.cursor.uleb();
            },
        }
        return null;
    }

    fn advance(self: *Rows, operations: u64) void {
        self.state.address +%= @truncate(operations *% self.header.min_instruction_length);
    }

    fn addLine(self: *Rows, delta: i64) void {
        const sum = @as(i64, self.state.line) +| delta;
        self.state.line = @intCast(std.math.clamp(sum, 0, std.math.maxInt(u32)));
    }
};

/// The source line `address` belongs to, or null when no sequence covers it.
pub fn lookup(sections: Sections, address: u32) Error!?Place {
    var offset: usize = 0;
    while (offset < sections.line.len) {
        const unit = try line_header.read(sections.line, offset);
        offset = unit.end;
        const span = try covering(unit.header, address) orelse continue;
        return .{
            .file = try line_header.file(unit.header, span.row.file, sections.strings),
            .line = span.row.line,
            .address = span.row.address,
            .end = span.end,
        };
    }
    return null;
}

const Span = struct { row: Row, end: u32 };

fn covering(header: Header, address: u32) Error!?Span {
    var rows = Rows.init(header);
    var previous: ?Row = null;
    while (try rows.next()) |row| {
        if (previous) |before| {
            if (before.address <= address and address < row.address) return .{ .row = before, .end = try lineEnd(&rows, before, row) };
        }
        previous = if (row.end_sequence) null else row;
    }
    return null;
}

/// Where `found`'s line ends: the first later row on another line or file,
/// or the sequence's end, the way gdb's `info line` reports it.
fn lineEnd(rows: *Rows, found: Row, after: Row) Error!u32 {
    var row = after;
    while (!row.end_sequence and row.line == found.line and row.file == found.file) {
        row = try rows.next() orelse break;
    }
    return row.address;
}

/// The line sections of an image, by name. A stripped image gives empty
/// sections, which a lookup answers with null.
pub fn ofImage(image: elf.Image) Sections {
    return .{
        .line = section(image, ".debug_line"),
        .strings = .{ .line_str = section(image, ".debug_line_str"), .str = section(image, ".debug_str") },
    };
}

/// A section's bytes by name, empty when the image has no such section or
/// its header points outside the file.
pub fn section(image: elf.Image, wanted: []const u8) []const u8 {
    const names_head = symbols.section(image, image.header().e_shstrndx) orelse return &.{};
    const names = bounded(image, names_head) orelse return &.{};
    var index: u16 = 0;
    while (index < image.header().e_shnum) : (index += 1) {
        const head = symbols.section(image, index) orelse continue;
        const name = dwarf_cursor.stringAt(names, head.sh_name) catch continue;
        if (std.mem.eql(u8, name, wanted)) return bounded(image, head) orelse &.{};
    }
    return &.{};
}

fn bounded(image: elf.Image, head: *align(1) const symbols.SectionHeader) ?[]const u8 {
    const from = @as(usize, head.sh_offset);
    const to = from + @as(usize, head.sh_size);
    if (to > image.bytes.len or from > to) return null;
    return image.bytes[from..to];
}
