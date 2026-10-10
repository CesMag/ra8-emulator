//! ThreadX threads' stack canaries for a soak (RA8EMU-619, slice 2).
//!
//! ThreadX fills each new thread's stack with 0xEFEFEFEF before linking it
//! into `_tx_thread_created_ptr`'s circular list, so the lowest stack word
//! (`tx_thread_stack_start`) still holds the fill until the stack overruns.
//! Offsets are TX_THREAD's in Eclipse ThreadX 6.4 on the Cortex-M ports:
//! `tx_thread_created_next` sits after TX_THREAD_EXTENSION_1 (empty there)
//! and before EXTENSION_2, so TrustZone and single-zone builds share it.
//!
//! The list is re-read only when `_tx_thread_created_count` moves. Canaries
//! are rebuilt from the list then, so a deleted thread's reused stack is
//! never reported as an overrun.
const soak_watch = @import("soak_watch.zig");

pub const created_ptr_symbol = "_tx_thread_created_ptr";
pub const created_count_symbol = "_tx_thread_created_count";
pub const stack_start_offset: u32 = 12;
pub const created_next_offset: u32 = 136;
/// TX_STACK_FILL without random stack filling.
pub const fill: u32 = 0xEFEF_EFEF;

pub const Threads = struct {
    /// Address of `_tx_thread_created_ptr`; null leaves threads unwatched.
    head: ?u32 = null,
    /// Address of `_tx_thread_created_count`; null re-reads every look.
    count_at: ?u32 = null,
    /// The count the canaries were last built from.
    seen: ?u32 = null,

    /// Rebuild the stack canaries when the created count has moved.
    /// `memory` is anything with `readWord(address) !u32`.
    pub fn refresh(self: *Threads, watch: *soak_watch.Watch, memory: anytype) void {
        const head = self.head orelse return;
        if (self.count_at) |at| {
            const count = memory.readWord(at) catch return;
            if (self.seen == count) return;
            self.seen = count;
        }
        watch.drop(.stack_canary);
        const first = memory.readWord(head) catch return;
        var thread = first;
        var walked: usize = 0;
        while (thread != 0 and walked < soak_watch.max_words) : (walked += 1) {
            watchStack(watch, memory, thread);
            thread = memory.readWord(thread +% created_next_offset) catch return;
            if (thread == first) return;
        }
    }
};

/// Watch `thread`'s lowest stack word if it still holds the fill.
fn watchStack(watch: *soak_watch.Watch, memory: anytype, thread: u32) void {
    const start = memory.readWord(thread +% stack_start_offset) catch return;
    for (watch.list()) |word| if (word.address == start) return;
    const now = memory.readWord(start) catch return;
    if (now != fill) return;
    watch.add(.{ .address = start, .expected = fill, .kind = .stack_canary }) catch return;
}
