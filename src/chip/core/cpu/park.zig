//! A park loop retires at once (RA8EMU-450).
//!
//! Firmware that has nothing left to do often spins in `b .` or a run of
//! NOPs ending in a branch back to the first of them. Such a loop reads and
//! writes nothing, so once the interrupt poll has settled on "nothing to
//! take", no trip round it can change what is pending before the stretch
//! ends: the board only moves at stretch boundaries (quiet_source.zig). `run`
//! then retires every whole trip that fits in what is left of the stretch in
//! one go, leaving the PC where those trips would have left it.
//!
//! It stays off whenever anyone watches single instructions (a retire
//! listener, the lockstep wrapper, which runs without a quiet source) and
//! for any block that is not tracked, so rewritten code never counts.
const Cpu = @import("cpu.zig").Cpu;
const regs_mod = @import("regs.zig");
const it_state = @import("it_state.zig");
const block = @import("block/block.zig");
const block_cache = @import("block_cache.zig");

/// The narrow NOP hint.
const nop: u16 = 0xBF00;

/// How many instructions `run` may retire at once from the PC: a whole
/// number of trips round a park loop, no more than `left`. 0 when the PC is
/// not on one or the core cannot be sure nothing changes meanwhile.
pub fn skippable(cpu: *const Cpu, left: u64) u64 {
    const found = calmHead(cpu) orelse return 0;
    const trip = tripLength(found) orelse return 0;
    if (left < trip) return 0;
    return left - left % trip;
}

/// The tracked block starting at the PC, when nothing watches single
/// instructions and the poll has settled, so no trip round a loop there can
/// change what is pending before the stretch ends. Shared with
/// fixed_trip.zig (RA8EMU-463).
pub fn calmHead(cpu: *const Cpu) ?*const block.Block {
    if (cpu.retire_listener != null or cpu.waiting != null) return null;
    const quiet = cpu.quiet orelse return null;
    if (!quiet.settled and !(quiet.hushed and quiet.clear)) return null;
    const cache = cpu.blocks orelse return null;
    if (cache.lines.dirty) return null;
    const xpsr = cpu.regs.xpsr;
    if (xpsr & regs_mod.xpsr_bits.thumb == 0 or xpsr & regs_mod.xpsr_bits.bti != 0) return null;
    if (it_state.active(it_state.get(xpsr))) return null;
    const pc = cpu.regs.pc;
    const found = &cache.blocks[(pc >> 1) & (block_cache.slots - 1)];
    if (found.len == 0 or found.start != pc or !found.tracked) return null;
    return found;
}

/// Instructions in one trip round `formed` when it is a park loop: narrow
/// NOPs, then a narrow unconditional B back to its first instruction.
pub fn tripLength(formed: *const block.Block) ?u64 {
    const all = formed.items();
    if (all.len == 0) return null;
    for (all[0 .. all.len - 1]) |one| {
        if (one.instr.size != 2 or one.instr.hw1 != nop) return null;
    }
    const last = all[all.len - 1].instr;
    if (last.size != 2 or last.hw1 & 0xF800 != 0xE000) return null;
    const offset: i32 = @as(i32, @as(i11, @bitCast(@as(u11, @truncate(last.hw1))))) * 2;
    const target = last.address +% 4 +% @as(u32, @bitCast(offset));
    return if (target == formed.start) all.len else null;
}
