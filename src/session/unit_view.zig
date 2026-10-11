//! The debug units' registers as a firmware load sees them on the Zig
//! core (RA8EMU-673), so a load of FP_CTRL, a DWT FUNCTION, an ITM port,
//! DHCSR or DFSR reads what the stop machine holds. The Zig core
//! has no such pass, so watch.bus.zig lays this view over the bytes a
//! firmware load read instead.
const stop_machine = @import("stop_machine.zig");
const fpb = @import("fpb.zig");
const dwt = @import("ra8_chip").periph.dwt;
const itm = @import("ra8_chip").periph.itm;
const dcb = @import("ra8_chip").periph.dcb;

/// The word at the word-aligned `address` as a load sees it, or null when
/// no debug unit owns it. `stored` is what memory holds there.
pub fn word(machine: *const stop_machine.Machine, address: u32, stored: u32) ?u32 {
    if (inside(address, fpb.base, fpb.limits.span)) return machine.fpb.read(address - fpb.base);
    if (address == dwt.base) return machine.dwt.ctrlWord(stored);
    if (inside(address, dwt.base, dwt.limits.end)) return machine.dwt.peek(address - dwt.base);
    if (inside(address, itm.base, itm.limits.span)) return machine.itm.peek(address - itm.base);
    if (address == dcb.dfsr_address) return machine.dcb.dfsr;
    if (inside(address, dcb.base, dcb.span)) return machine.dcb.peek(address - dcb.base);
    return null;
}

/// Lay the units' view over `into`, the bytes a load read at `address`.
/// Bytes outside any unit register are left as memory held them.
pub fn overlay(machine: *const stop_machine.Machine, address: u32, into: []u8) void {
    const end: u64 = @as(u64, address) + into.len;
    var at: u64 = address & ~@as(u32, 3);
    while (at < end) : (at += 4) {
        var bytes: [4]u8 = .{ 0, 0, 0, 0 };
        const from = @max(at, address);
        const to = @min(at + 4, end);
        copy(bytes[from - at .. to - at], into[from - address .. to - address]);
        const seen = word(machine, @intCast(at), readLittle(bytes)) orelse continue;
        bytes = writeLittle(seen);
        copy(into[from - address .. to - address], bytes[from - at .. to - at]);
    }
}

fn copy(into: []u8, from: []const u8) void {
    for (into, from) |*dest, byte| dest.* = byte;
}

fn readLittle(bytes: [4]u8) u32 {
    return @as(u32, bytes[0]) | @as(u32, bytes[1]) << 8 | @as(u32, bytes[2]) << 16 | @as(u32, bytes[3]) << 24;
}

fn writeLittle(value: u32) [4]u8 {
    return .{ @truncate(value), @truncate(value >> 8), @truncate(value >> 16), @truncate(value >> 24) };
}

fn inside(address: u64, from: u32, span: u32) bool {
    return address >= from and address < @as(u64, from) + span;
}
