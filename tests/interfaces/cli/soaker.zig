//! A built-in soak image for RA8EMU-186's done tests: idler.zig's counting
//! SysTick handler at its longest period, and a reset handler that sleeps
//! until the handler has run `wakes` times, then pushes past MSPLIM.
const memmap = @import("ra8").chip.core.memmap;
const idler = @import("idler.zig");

pub const base = idler.base;
pub const reset_at = idler.base + 0x200;
pub const hang_at = reset_at + 0x20;
pub const counter_at = idler.counter_at;
/// SysTick's longest period, 2^24 cycles.
pub const period: u64 = 1 << 24;
/// Wakes before the overflow: at 1 MHz, 215 periods end at 3607.1 s.
pub const wakes: u8 = 215;
/// Two 32-byte pushes fit above the limit, a third overflows.
pub const limit = memmap.sram_end - 64;

/// The idle image with only SysTick's period and the reset handler swapped:
/// clean is idler.zig sleeping at the long period, overflow adds the wake
/// count and the pushes.
pub fn load(core: anytype, overflow: bool) !void {
    try idler.load(core);
    try core.writeWord(memmap.syst.rvr, @intCast(period - 1));
    if (!overflow) return;
    try core.writeWord(idler.base + 4, reset_at | 1);
    try core.writeWord(idler.base + 3 * 4, hang_at | 1);
    // ldr r0, =limit; msr msplim, r0
    try core.writeWord(reset_at, 0xF380_480B);
    // (msr cont.); wfi
    try core.writeWord(reset_at + 4, 0xBF30_880A);
    // ldr r1, =counter; ldr r1, [r1]
    try core.writeWord(reset_at + 8, 0x6809_490A);
    // cmp r1, #wakes; bne wfi
    try core.writeWord(reset_at + 12, 0xD1FA_2900 | @as(u32, wakes));
    // push {r0-r7}; b push
    try core.writeWord(reset_at + 16, 0xE7FD_B4FF);
    // b .
    try core.writeWord(hang_at, 0xE7FE_E7FE);
    try core.writeWord(reset_at + 0x30, limit);
    try core.writeWord(reset_at + 0x34, counter_at);
}
