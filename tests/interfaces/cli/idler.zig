//! A built-in idle-heavy image for time tests (RA8EMU-185, RA8EMU-183): a
//! reset handler that sleeps in `wfi; b .-2` forever and a SysTick handler
//! that adds one to a RAM counter, with SysTick slower than a chunk so a
//! sleeping stretch can really be widened.
const memmap = @import("ra8").chip.core.memmap;

pub const base = memmap.sram_base;
pub const reset_at = base + 0x40;
pub const handler_at = base + 0x48;
pub const counter_at = base + 0x100;
pub const chunk: u32 = 5_000;
pub const period: u32 = 200_000;

/// Vectors, the sleeping reset handler, and the counting SysTick handler.
pub fn load(core: anytype) !void {
    try core.writeWord(base, memmap.sram_end);
    try core.writeWord(base + 4, reset_at | 1);
    try core.writeWord(base + 15 * 4, handler_at | 1);
    try core.writeWord(reset_at, 0xE7FD_BF30);
    try core.writeWord(handler_at, 0x6801_4802);
    try core.writeWord(handler_at + 4, 0x6001_3101);
    try core.writeWord(handler_at + 8, 0xBF00_4770);
    try core.writeWord(handler_at + 12, counter_at);
    try core.writeWord(counter_at, 0);
    try core.writeWord(memmap.syst.rvr, period - 1);
    try core.writeWord(memmap.syst.cvr, 0);
    try core.writeWord(memmap.syst.csr, 0x7);
}
