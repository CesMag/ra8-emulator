//! The digest and the first difference of save streams taken from two
//! builds of one program.
//!
//! A checkpoint's object is the run's whole save stream, which names the
//! image it ran and holds the image's own bytes in guest memory. Two builds
//! that behave alike must still digest alike, so the image section is left
//! out and memory is read as what the program did to it
//! (state_memory.zig). Everything else, every core's registers and every
//! board section, is hashed as written.
const std = @import("std");
const file = @import("ra8_board").snapshot.run.file;
const fields = @import("ra8_board").snapshot.run.fields;
const regs_mod = @import("ra8_chip").core.cpu.regs;
const elf = @import("ra8_board").image.elf;
const memory = @import("state_memory.zig");

pub const Digest = [16]u8;
pub const Error = file.Error || fields.Error || memory.Error || error{WriteFailed};

const Units = @import("../board/state.zig").Units;

/// Room for a debug-units section of one or two cores.
const debug_scratch: usize = 1 << 15;

/// The debug-units section with each core's slot clock cleared. That clock
/// counts the slots of the run command in flight, so it follows how the run
/// was chunked into commands and not what the guest did; every other field
/// is the debug unit's own state and stays.
fn withoutRunBookkeeping(payload: []const u8, out: []u8) Error![]const u8 {
    var cursor: fields.Cursor = .{ .bytes = payload };
    var writer: std.Io.Writer = .fixed(out);
    const cores = try fields.read(u8, &cursor);
    try fields.write(&writer, cores);
    for (0..cores) |_| {
        var units = try fields.read(Units, &cursor);
        units.count = .{};
        try fields.write(&writer, units);
    }
    return writer.buffered();
}

fn isMemory(kind: file.Kind) bool {
    return kind == .memory or kind == .second_memory;
}

/// Blake3-128 over the stream's sections but the image's.
pub fn digest(stream: []const u8, image: elf.Image) Error!Digest {
    var hasher = std.crypto.hash.Blake3.init(.{});
    var reader = try file.Reader.open(stream);
    while (try reader.next()) |section| {
        if (section.kind == .image) continue;
        hasher.update(std.mem.asBytes(&std.mem.nativeToLittle(u32, @backingInt(section.kind))));
        if (isMemory(section.kind)) {
            memory.hash(&hasher, try memory.parse(section.payload), image);
        } else if (section.kind == .debug_units) {
            var scratch: [debug_scratch]u8 = undefined;
            hasher.update(try withoutRunBookkeeping(section.payload, &scratch));
        } else {
            hasher.update(section.payload);
        }
    }
    var full: [32]u8 = undefined;
    hasher.final(&full);
    return full[0..16].*;
}

/// What first differs: a register, a byte of memory, or a whole section
/// that is not told apart further.
pub const Place = union(enum) {
    register: struct { name: []const u8, expected: u32, actual: u32 },
    memory: memory.Spot,
    section: file.Kind,
};

/// The first difference, with the core it belongs to (the core whose state
/// section differs, else core 0) and both cores' program counters.
pub const Difference = struct {
    core: u8,
    pc_expected: u32,
    pc_actual: u32,
    place: Place,
};

fn registersOf(section: file.Section) Error!struct { core: u8, regs: regs_mod.Regs } {
    comptime std.debug.assert(std.mem.eql(u8, @import("ra8_chip").core.cpu.snapshot.saved[0], "regs"));
    var cursor: fields.Cursor = .{ .bytes = section.payload };
    const core = try fields.read(u8, &cursor);
    return .{ .core = core, .regs = try fields.read(regs_mod.Regs, &cursor) };
}

/// The first register of `b` that is not `a`'s, by name.
fn firstRegister(a: regs_mod.Regs, b: regs_mod.Regs) ?Place {
    inline for (@typeInfo(regs_mod.Regs).@"struct".field_names) |name| {
        const x = @field(a, name);
        const y = @field(b, name);
        switch (@typeInfo(@TypeOf(x))) {
            .int => if (x != y) return .{ .register = .{ .name = name, .expected = x, .actual = y } },
            .array => |array| if (array.child == u32) {
                inline for (0..array.len) |i| {
                    if (x[i] != y[i]) return .{ .register = .{
                        .name = if (comptime std.mem.eql(u8, name, "low")) std.fmt.comptimePrint("r{d}", .{i}) else std.fmt.comptimePrint("{s}[{d}]", .{ name, i }),
                        .expected = x[i],
                        .actual = y[i],
                    } };
                }
            },
            else => if (!std.meta.eql(x, y)) return .{ .register = .{ .name = name, .expected = 0, .actual = 0 } },
        }
    }
    return null;
}

/// The first place the two streams differ, or null when they digest alike.
/// Sections are compared in stream order: a core's registers before the
/// rest of its state, memory by address.
pub fn first(expected: []const u8, expected_image: elf.Image, actual: []const u8, actual_image: elf.Image) Error!?Difference {
    var a = try file.Reader.open(expected);
    var b = try file.Reader.open(actual);
    var core: u8 = 0;
    while (true) {
        const x = try nextSection(&a);
        const y = try nextSection(&b);
        if (x == null and y == null) return null;
        const one = x orelse return try finish(expected, actual, core, .{ .section = y.?.kind });
        const two = y orelse return try finish(expected, actual, core, .{ .section = one.kind });
        if (one.kind != two.kind) return try finish(expected, actual, core, .{ .section = one.kind });
        if (one.kind == .cpu) {
            const ra = try registersOf(one);
            core = ra.core;
            if (firstRegister(ra.regs, (try registersOf(two)).regs)) |place| return try finish(expected, actual, core, place);
        }
        if (isMemory(one.kind)) {
            const pa = try memory.parse(one.payload);
            const pb = try memory.parse(two.payload);
            if (memory.firstDifference(pa, expected_image, pb, actual_image)) |spot| return try finish(expected, actual, core, .{ .memory = spot });
            if (!std.mem.eql(u8, pa.tail, pb.tail)) return try finish(expected, actual, core, .{ .section = one.kind });
        } else if (one.kind == .debug_units) {
            var scratch: [2][debug_scratch]u8 = undefined;
            const left = try withoutRunBookkeeping(one.payload, &scratch[0]);
            const right = try withoutRunBookkeeping(two.payload, &scratch[1]);
            if (!std.mem.eql(u8, left, right)) return try finish(expected, actual, core, .{ .section = one.kind });
        } else if (!std.mem.eql(u8, one.payload, two.payload)) {
            return try finish(expected, actual, core, .{ .section = one.kind });
        }
    }
}

fn nextSection(reader: *file.Reader) Error!?file.Section {
    while (try reader.next()) |section| {
        if (section.kind != .image) return section;
    }
    return null;
}

/// `core`'s program counter in `stream`, zero when it holds none.
pub fn pcOf(stream: []const u8, core: u8) Error!u32 {
    var reader = try file.Reader.open(stream);
    while (try reader.next()) |section| {
        if (section.kind != .cpu) continue;
        const found = try registersOf(section);
        if (found.core == core) return found.regs.pc;
    }
    return 0;
}

fn finish(expected: []const u8, actual: []const u8, core: u8, place: Place) Error!Difference {
    return .{ .core = core, .pc_expected = try pcOf(expected, core), .pc_actual = try pcOf(actual, core), .place = place };
}
