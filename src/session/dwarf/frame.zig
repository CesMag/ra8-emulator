//! Call frame information from DWARF .debug_frame: at a given pc, where
//! the caller's frame (the CFA) is and where each register was saved.
//!
//! An FDE covers a range of code and points at the CIE it shares with its
//! neighbours. The CIE's initial instructions, then the FDE's own, are run
//! up to the pc, giving one row of the table the compiler described. Only
//! 32-bit DWARF and register rules are taken; a DWARF expression rule is
//! Unsupported, and the caller falls back to whatever it did before.
const std = @import("std");
const dwarf_cursor = @import("cursor.zig");

const Cursor = dwarf_cursor.Cursor;
pub const Error = dwarf_cursor.Error || error{
    /// More remember_state than a frame can hold, or a restore of none.
    BadState,
};

pub const limits = struct {
    /// r0 to r15: the registers a rule can be about.
    pub const registers: usize = 16;
    /// How deep remember_state may nest.
    pub const remembered: usize = 4;
    /// The CIE id in .debug_frame: an entry with it is a CIE, not an FDE.
    pub const cie_id: u32 = 0xffff_ffff;
    /// A length with this value or above escapes to 64-bit DWARF.
    pub const dwarf64_escape: u32 = 0xffff_fff0;
};

/// Where one register of the caller is.
pub const Rule = union(enum) {
    /// Not saved: the caller's value is the callee's.
    same,
    /// Lost: the compiler kept no copy.
    undefined,
    /// Saved in memory at CFA + offset.
    offset: i64,
    /// Held in another register.
    register: u8,
};

/// CFA = register + offset.
pub const Cfa = struct {
    register: u8 = 13,
    offset: i64 = 0,
};

/// One row of the table: the CFA and every register's rule at a pc.
pub const Row = struct {
    cfa: Cfa = .{},
    rules: [limits.registers]Rule = @splat(.same),
};

/// What a CIE says about every FDE that points at it.
pub const Cie = struct {
    code_align: u64,
    data_align: i64,
    return_register: u64,
    instructions: []const u8,
};

/// One FDE: the code it covers and the instructions that describe it.
pub const Fde = struct {
    cie: Cie,
    start: u32,
    end: u32,
    instructions: []const u8,
};

/// The FDE covering `pc`, or null when no entry does.
pub fn find(frame: []const u8, pc: u32) Error!?Fde {
    var offset: usize = 0;
    while (offset < frame.len) {
        var cursor = Cursor{ .bytes = frame, .at = offset };
        const body = try entry(&cursor);
        offset = cursor.at;
        var fields = Cursor{ .bytes = body };
        const id = try fields.int(u32);
        if (id == limits.cie_id) continue;
        const start = try fields.int(u32);
        const range = try fields.int(u32);
        if (pc < start or pc - start >= range) continue;
        return .{
            .cie = try cieAt(frame, id),
            .start = start,
            .end = start +% range,
            .instructions = fields.bytes[fields.at..],
        };
    }
    return null;
}

/// One entry's body, after its length, leaving the cursor past it.
fn entry(cursor: *Cursor) Error![]const u8 {
    const length = try cursor.int(u32);
    if (length >= limits.dwarf64_escape) return Error.Unsupported;
    return cursor.take(length);
}

fn cieAt(frame: []const u8, offset: u32) Error!Cie {
    var cursor = Cursor{ .bytes = frame, .at = std.math.cast(usize, offset) orelse return Error.Truncated };
    if (cursor.at > frame.len) return Error.Truncated;
    var fields = Cursor{ .bytes = try entry(&cursor) };
    if (try fields.int(u32) != limits.cie_id) return Error.Unsupported;
    const version = try fields.byte();
    const augmentation = try fields.string();
    if (augmentation.len != 0) return Error.Unsupported;
    if (version >= 4) {
        if (try fields.byte() != @sizeOf(u32)) return Error.Unsupported;
        if (try fields.byte() != 0) return Error.Unsupported;
    }
    const code_align = try fields.uleb();
    const data_align = try fields.sleb();
    const return_register = if (version == 1) try fields.byte() else try fields.uleb();
    return .{
        .code_align = code_align,
        .data_align = data_align,
        .return_register = return_register,
        .instructions = fields.bytes[fields.at..],
    };
}

/// The table's row at `pc` for this FDE.
pub fn rowAt(fde: Fde, pc: u32) Error!Row {
    var initial = Machine{ .cie = fde.cie, .location = fde.start, .stop = pc };
    try initial.run(fde.cie.instructions);
    var machine = initial;
    machine.initial = initial.row;
    try machine.run(fde.instructions);
    return machine.row;
}

/// The CFA program's state as it runs.
const Machine = struct {
    cie: Cie,
    location: u32,
    stop: u32,
    row: Row = .{},
    /// The row after the CIE's instructions, which `restore` goes back to.
    initial: Row = .{},
    remembered: [limits.remembered]Row = undefined,
    depth: usize = 0,

    fn run(self: *Machine, program: []const u8) Error!void {
        var cursor = Cursor{ .bytes = program };
        while (!cursor.done()) {
            const opcode = try cursor.byte();
            const low: u8 = opcode & 0x3f;
            const moved = switch (opcode >> 6) {
                1 => self.advance(low),
                2 => blk: {
                    try self.save(low, @as(i64, @intCast(try cursor.uleb())) * self.cie.data_align);
                    break :blk true;
                },
                3 => blk: {
                    try self.restore(low);
                    break :blk true;
                },
                else => try self.extended(opcode, &cursor),
            };
            if (!moved) return;
        }
    }

    /// Move the location on; false once it has passed the pc asked about.
    fn advance(self: *Machine, delta: u64) bool {
        const step = std.math.mul(u64, delta, self.cie.code_align) catch return false;
        const next = @as(u64, self.location) + step;
        if (next > self.stop) return false;
        self.location = @intCast(next);
        return true;
    }

    fn extended(self: *Machine, opcode: u8, cursor: *Cursor) Error!bool {
        switch (opcode) {
            0x00 => {},
            0x01 => {
                const to = try cursor.int(u32);
                if (to > self.stop) return false;
                self.location = to;
            },
            0x02 => return self.advance(try cursor.byte()),
            0x03 => return self.advance(try cursor.int(u16)),
            0x04 => return self.advance(try cursor.int(u32)),
            0x05 => try self.save(try cursor.uleb(), try factored(cursor, self.cie.data_align)),
            0x06 => try self.restore(try cursor.uleb()),
            0x07 => try self.set(try cursor.uleb(), .undefined),
            0x08 => try self.set(try cursor.uleb(), .same),
            0x09 => {
                const which = try cursor.uleb();
                try self.set(which, .{ .register = try register(try cursor.uleb()) });
            },
            0x0a => try self.remember(),
            0x0b => try self.recall(),
            0x0c => {
                self.row.cfa.register = try register(try cursor.uleb());
                self.row.cfa.offset = @intCast(try cursor.uleb());
            },
            0x0d => self.row.cfa.register = try register(try cursor.uleb()),
            0x0e => self.row.cfa.offset = @intCast(try cursor.uleb()),
            0x11 => try self.save(try cursor.uleb(), try cursor.sleb() * self.cie.data_align),
            0x12 => {
                self.row.cfa.register = try register(try cursor.uleb());
                self.row.cfa.offset = try cursor.sleb() * self.cie.data_align;
            },
            0x13 => self.row.cfa.offset = try cursor.sleb() * self.cie.data_align,
            else => return Error.Unsupported,
        }
        return true;
    }

    fn factored(cursor: *Cursor, data_align: i64) Error!i64 {
        const value = std.math.cast(i64, try cursor.uleb()) orelse return Error.Unsupported;
        return value * data_align;
    }

    fn save(self: *Machine, which: u64, offset: i64) Error!void {
        try self.set(which, .{ .offset = offset });
    }

    fn restore(self: *Machine, which: u64) Error!void {
        const index = try register(which);
        self.row.rules[index] = self.initial.rules[index];
    }

    fn set(self: *Machine, which: u64, rule: Rule) Error!void {
        // A rule about a register past r15 (an FP or vector register)
        // cannot change where a caller's core registers are.
        const index = std.math.cast(u8, which) orelse return;
        if (index >= limits.registers) return;
        self.row.rules[index] = rule;
    }

    fn remember(self: *Machine) Error!void {
        if (self.depth == limits.remembered) return Error.BadState;
        self.remembered[self.depth] = self.row;
        self.depth += 1;
    }

    /// Back to the remembered row, CFA included, as gdb and libgcc do.
    fn recall(self: *Machine) Error!void {
        if (self.depth == 0) return Error.BadState;
        self.depth -= 1;
        self.row = self.remembered[self.depth];
    }
};

fn register(value: u64) Error!u8 {
    if (value >= limits.registers) return Error.Unsupported;
    return @intCast(value);
}
