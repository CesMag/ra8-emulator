//! RA8EMU-1149 fixture: two threads the way ThreadX names them, without
//! ThreadX. `Reset_Handler` stores `tcb_a`'s address in
//! `_tx_thread_current_ptr` and runs `thread_a_outer` (which calls
//! `thread_a_leaf`, two units of work), then stores `tcb_b`'s and runs
//! `thread_b_outer` (calling `thread_b_leaf`, one unit). A sampled run with
//! the RTOS trace on tags each stack with the control block in force, so
//! the folded profile splits by thread. The word at SRAM 0x22000100 counts
//! rounds.
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

/// The word the RTOS trace watches: the running thread's control block.
export var _tx_thread_current_ptr: u32 = 0;
/// Stand-in control blocks; only their addresses matter.
export var tcb_a: u32 = 0;
export var tcb_b: u32 = 0;

fn switchTo(block: *u32) void {
    const current: *volatile u32 = &_tx_thread_current_ptr;
    current.* = @intFromPtr(block);
}

export fn thread_a_leaf() callconv(.c) void {
    work.spin(2 * work.unit);
}

export fn thread_a_outer() callconv(.c) void {
    thread_a_leaf();
}

export fn thread_b_leaf() callconv(.c) void {
    work.spin(work.unit);
}

export fn thread_b_outer() callconv(.c) void {
    thread_b_leaf();
}

export fn Reset_Handler() callconv(.c) noreturn {
    rounds.* = 0;
    while (true) {
        switchTo(&tcb_a);
        thread_a_outer();
        switchTo(&tcb_b);
        thread_b_outer();
        rounds.* += 1;
    }
}
