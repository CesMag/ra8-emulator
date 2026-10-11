//! Thread names for `--trace-rtos` (RA8EMU-223).
//!
//! ThreadX keeps `CHAR *tx_thread_name` at byte 40 of a TX_THREAD on the
//! Cortex-M85 and Cortex-M33 GNU ports. Ten words come first (id, run
//! count, stack pointer, stack start, stack end, stack size, time slice,
//! new time slice, ready next, ready previous), and TX_THREAD_EXTENSION_0,
//! which sits between them and the name, is empty on both ports. Taken from
//! common/inc/tx_api.h and ports/cortex_m{85,33}/gnu/inc/tx_port.h at the
//! ThreadX revision the firmware pins.
//!
//! This file only knows the layout. Whatever reads target memory is passed
//! in, so the lookup needs nothing from the core.
const std = @import("std");

/// Where the name pointer sits in a TX_THREAD.
pub const name_offset: u32 = 40;

/// The most of a name that is read; a longer one is shown cut short.
pub const longest = 32;

/// The name of the thread whose control block is at `thread`, read through
/// `memory`: anything with `read(address: u32, into: []u8) bool`. Null when
/// the block or its name cannot be read, the pointer is zero, or the name is
/// empty or not text, so the trace falls back to the bare pointer.
pub fn name(memory: anytype, thread: u32, buffer: *[longest]u8) ?[]const u8 {
    var word: [4]u8 = undefined;
    if (!memory.read(thread +% name_offset, &word)) return null;
    const at = std.mem.readInt(u32, &word, .little);
    if (at == 0) return null;
    var count: usize = 0;
    while (count < longest) : (count += 1) {
        if (!memory.read(at +% @as(u32, @intCast(count)), buffer[count .. count + 1])) return null;
        const byte = buffer[count];
        if (byte == 0) break;
        if (byte < 0x20 or byte > 0x7E) return null;
    }
    if (count == 0) return null;
    return buffer[0..count];
}

/// Memory that reads nothing: the trace without names.
pub const none = struct {
    pub fn read(_: @This(), _: u32, _: []u8) bool {
        return false;
    }
}{};
