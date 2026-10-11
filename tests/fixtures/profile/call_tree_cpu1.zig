//! RA8EMU-955 fixture, CPU1's half: the same shape as call_tree.zig with
//! its own names and a different split, so the two cores' trees tell
//! apart: `cpu1_outer` calls `cpu1_wide` (two units) and `cpu1_narrow`
//! (one unit), so about two thirds of CPU1's samples sit under
//! `cpu1_wide`. The word at SRAM 0x22190100 counts rounds.
const rounds: *volatile u32 = @ptrFromInt(0x2219_0100);
const work = @import("work.zig");

const Vectors = extern struct {
    sp: u32,
    reset: *const fn () callconv(.c) noreturn,
};

export const vector_table linksection(".isr_vector") = Vectors{
    .sp = 0x2219_8000,
    .reset = &Reset_Handler,
};

export fn cpu1_wide() callconv(.c) void {
    work.spin(2 * work.unit);
}

export fn cpu1_narrow() callconv(.c) void {
    work.spin(work.unit);
}

export fn cpu1_outer() callconv(.c) void {
    cpu1_wide();
    cpu1_narrow();
}

export fn Reset_Handler() callconv(.c) noreturn {
    rounds.* = 0;
    while (true) {
        cpu1_outer();
        rounds.* += 1;
    }
}
