//! How a session prints what it reads: registers, memory, an instruction.
//!
//! src/session/session.zig decides what to print; this file decides how, so
//! the formats sit in one place and a transcript changes only when one of
//! them does.
const std = @import("std");
const disasm = @import("disasm.zig");
const core_view = @import("core_view.zig");
const registers_list = @import("registers.zig");

pub const limits = struct {
    /// Words on one line of `x`.
    pub const words_per_line: u32 = 4;
};

pub const encoding = struct {
    /// A first halfword at or above this, with its top five bits 0b11101,
    /// 0b11110 or 0b11111, starts a 32-bit Thumb instruction.
    pub const wide_first: u16 = 0xE800;
    pub const narrow: u32 = 2;
    pub const wide: u32 = 4;
};

/// The core registers, in the order a register dump prints them.
pub fn registers(out: anytype, core: core_view.View) !void {
    for (registers_list.dumped, 0..) |named, index| {
        const value = try core.register(named.which);
        try out.print("{s: <3} 0x{X:0>8}", .{ named.name, value });
        try out.print("{s}", .{if (registers_list.endsLine(index)) "\n" else "  "});
    }
}

/// `count` words from `address`, a line every four.
pub fn words(out: anytype, core: core_view.View, address: u32, count: u32) !void {
    for (0..count) |step| {
        const index: u32 = @intCast(step);
        const at = address +% index * @sizeOf(u32);
        if (index % limits.words_per_line == 0) try out.print("0x{X:0>8}:", .{at});
        if (core.readWord(at)) |value| {
            try out.print(" 0x{X:0>8}", .{value});
        } else |_| {
            try out.print(" <unreadable>", .{});
        }
        const last = index + 1 == count;
        if (last or (index + 1) % limits.words_per_line == 0) try out.print("\n", .{});
    }
}

/// The word at a place, in hex and in decimal.
pub fn word(out: anytype, core: core_view.View, text: []const u8, address: u32) !void {
    const read = try core.readWord(address);
    try out.print("{s} = 0x{X:0>8} ({d})\n", .{ text, read, read });
}

/// The instruction at `address`, and how many bytes it takes.
pub fn instruction(out: anytype, core: core_view.View, address: u32) !u32 {
    var bytes: [4]u8 = undefined;
    core.read(address, bytes[0..2]) catch {
        try out.print("<unreadable>", .{});
        return encoding.narrow;
    };
    const first = std.mem.readInt(u16, bytes[0..2], .little);
    const width: u32 = if (first >= encoding.wide_first) encoding.wide else encoding.narrow;
    if (width == encoding.wide) core.read(address + 2, bytes[2..4]) catch {
        try out.print("<unreadable>", .{});
        return width;
    };
    const text = disasm.one(address, bytes[0..width]) catch {
        try out.print("<undecoded 0x{X:0>4}>", .{first});
        return width;
    };
    try out.print("{s}", .{text.slice()});
    return width;
}
