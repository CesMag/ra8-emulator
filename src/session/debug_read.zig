//! How the debugger reads a range of guest memory (RA8EMU-938, RA8EMU-948).
//!
//! A peripheral window answers one register access of 1, 2 or 4 bytes, so a
//! debugger range that touches one goes through as naturally aligned pieces
//! of those widths. Each piece is peeked first, so a block that can show a
//! register without popping a FIFO or clearing a status bit does, and it is
//! read the way a load reads it only when its block keeps no peek. A range
//! that touches no window is one access, as it always was.
const bus = @import("ra8_chip").core.cpu.bus;
const registry = @import("ra8_chip").periph.registry;

pub fn read(b: bus.Bus, address: u32, into: []u8) bus.Error!void {
    if (!touchesWindow(address, into.len)) return b.read(address, into);
    var done: usize = 0;
    while (done < into.len) {
        const at = address +% @as(u32, @truncate(done));
        const part = into[done..][0..piece(at, into.len - done)];
        if (!b.peek(at, part)) try b.read(at, part);
        done += part.len;
    }
}

/// The widest naturally aligned access at `at` that fits in `left` bytes.
pub fn piece(at: u32, left: usize) usize {
    if (at % 4 == 0 and left >= 4) return 4;
    if (at % 2 == 0 and left >= 2) return 2;
    return 1;
}

/// Whether any byte of the range lands in the Secure peripheral window or
/// its Non-secure alias.
pub fn touchesWindow(address: u32, len: usize) bool {
    if (len == 0) return false;
    const first: u64 = address;
    const end = first + len;
    for ([_]u64{ registry.base, registry.ns_base }) |window| {
        if (first < window + registry.size and end > window) return true;
    }
    return false;
}
