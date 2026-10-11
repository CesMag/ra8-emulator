//! RA8EMU-955 fixture, CPU0's half: a known call tree for the sampled
//! folded profile. `Reset_Handler` loops forever over `outer`, which calls
//! `heavy` (three units of work) and `light` (one unit), so a sampled run
//! spends about three quarters of its samples under
//! `Reset_Handler;outer;heavy` and one quarter under
//! `Reset_Handler;outer;light`. The word at SRAM 0x22000100 counts rounds.
const rounds: *volatile u32 = @ptrFromInt(0x2200_0100);
const work = @import("work.zig");

const Vectors = extern struct {
    sp: u32,
    reset: *const fn () callconv(.c) noreturn,
};

export const vector_table linksection(".isr_vector") = Vectors{
    .sp = 0x2208_0000,
    .reset = &Reset_Handler,
};

export fn heavy() callconv(.c) void {
    work.spin(3 * work.unit);
}

export fn light() callconv(.c) void {
    work.spin(work.unit);
}

export fn outer() callconv(.c) void {
    heavy();
    light();
}

export fn Reset_Handler() callconv(.c) noreturn {
    rounds.* = 0;
    while (true) {
        outer();
        rounds.* += 1;
    }
}
