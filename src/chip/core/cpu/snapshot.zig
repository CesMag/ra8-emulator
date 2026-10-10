//! One core's architectural state in a snapshot (RA8EMU-658): the register
//! file, the banked Secure/Non-secure copies, FP and MVE state, the active
//! exception stack, VTOR, the raised exception, the exclusive monitor, the
//! event register, any WFI/WFE wait and the retired count.
//!
//! Wiring is left as the board built it: the bus, exception source, caches,
//! MPU and attribution hooks, listeners and the profile. Peripheral state
//! outside guest memory is RA8EMU-564's. Load into a freshly built board, so
//! no decode or block cache holds code from before the load.
const std = @import("std");
const file = @import("ra8_snapshot").file;
const fields = @import("ra8_snapshot").fields;
const Cpu = @import("cpu.zig").Cpu;
const Entry = @import("exception/active.zig").Entry;

pub const Error = file.Error || fields.Error || error{Missing};

/// The Cpu fields saved whole, in format order. Appending is a format change.
const saved = .{ "regs", "fp", "retired", "vtor", "raised", "exclusive", "banked", "entering_non_secure", "secure_faults", "event", "waiting" };

/// A cpu section for `core` (0 for CPU0, 1 for CPU1).
pub fn save(cpu: *const Cpu, core: u8, writer: anytype) !void {
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try body(cpu, core, &counter.writer);
    try file.writeSectionHeader(writer, .cpu, counter.fullCount());
    try body(cpu, core, writer);
}

fn body(cpu: *const Cpu, core: u8, writer: anytype) !void {
    try fields.write(writer, core);
    inline for (saved) |name| try fields.write(writer, @field(cpu, name));
    // Only the live entries: the rest of the stack is undefined.
    const live = cpu.active.stack[0..cpu.active.depth];
    try fields.write(writer, @as(u8, @intCast(live.len)));
    for (live) |entry| try fields.write(writer, entry);
}

/// Restores `core`'s state from a whole snapshot file. On any error the
/// core is left exactly as it was.
pub fn load(cpu: *Cpu, core: u8, bytes: []const u8) Error!void {
    var reader = try file.Reader.open(bytes);
    while (try reader.next()) |section| {
        if (section.kind != .cpu) continue;
        var cursor: fields.Cursor = .{ .bytes = section.payload };
        if (try fields.read(u8, &cursor) != core) continue;
        return apply(cpu, &cursor);
    }
    return Error.Missing;
}

fn apply(cpu: *Cpu, cursor: *fields.Cursor) Error!void {
    var next = cpu.*;
    inline for (saved) |name| @field(next, name) = try fields.read(@TypeOf(@field(next, name)), cursor);
    const depth = try fields.read(u8, cursor);
    if (depth > next.active.stack.len) return Error.BadValue;
    for (next.active.stack[0..depth]) |*entry| entry.* = try fields.read(Entry, cursor);
    next.active.depth = depth;
    if (!cursor.done()) return Error.BadValue;
    cpu.* = next;
}
