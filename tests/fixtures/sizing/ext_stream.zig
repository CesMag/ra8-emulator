//! External-memory sizing fixture (RA8EMU-755): streams a fixed amount of
//! data through the OSPI and SDRAM windows so `ra8_emulator sweep --elf`
//! has traffic to time across the memory matrix. Every word is read from
//! OSPI and written to SDRAM, then read back. A checksum and the marker
//! `0x5EE9C0DE` go to SRAM `0x22000100` when the run is done.
//! Built freestanding with Zig 0.17.0; see README.md for the command.

const ospi: [*]const volatile u32 = @ptrFromInt(0x8000_0000);
const sdram: [*]volatile u32 = @ptrFromInt(0x6800_0000);
const results: [*]volatile u32 = @ptrFromInt(0x2200_0100);

/// Set to 1 once the traffic is done, so `--stop-sym ext_stream_done 1`
/// ends the run there and its elapsed time is the time the traffic took.
export var ext_stream_done: u32 = 0;

/// 64 KiB through each window.
const words: usize = 16 * 1024;

export fn main() noreturn {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i < words) : (i += 1) {
        const value = ospi[i] +% @as(u32, @intCast(i));
        sdram[i] = value;
        sum +%= value;
    }
    i = 0;
    while (i < words) : (i += 1) sum +%= sdram[i];
    results[0] = sum;
    results[1] = 0x5EE9_C0DE;
    @as(*volatile u32, &ext_stream_done).* = 1;
    while (true) asm volatile ("wfi");
}
