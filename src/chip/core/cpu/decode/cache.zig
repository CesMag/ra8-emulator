//! The decoded-instruction cache (RA8EMU-317).
//!
//! The decoder asks every group in ops/table.zig in turn, which is most of
//! what a step costs once the interrupt poll is quiet. Firmware spends its
//! time in loops, so the same addresses come round again and again: keep the
//! last decode for each address in a direct-mapped table and reuse it while
//! the fetched halfwords still match. The halfwords are fetched every step
//! anyway, so code rewritten under the cache can never run a stale decode.
const decode = @import("decode.zig");
const Instr = @import("../instr.zig").Instr;

/// Slots in the table: a power of two, indexed by halfword address.
pub const slots: usize = 4096;

const Slot = struct {
    address: u32 = 0,
    hw1: u16 = 0,
    hw2: u16 = 0,
    /// Null for a slot nothing has been decoded into.
    hit: ?decode.Hit = null,
};

pub const DecodeCache = struct {
    table: [slots]Slot = @splat(.{}),
    /// Lookups the table answered, and lookups that had to walk the groups.
    hits: u64 = 0,
    misses: u64 = 0,

    /// The decode of `instr`: from the table when the same halfwords were
    /// decoded at the same address last time, else from the decoder. An
    /// encoding no group knows is not cached.
    pub fn find(self: *DecodeCache, instr: Instr) ?decode.Hit {
        return self.findFor(decode.profile.Profile.m85, instr);
    }

    /// `find` for a core with profile `core`. One cache serves one core, so
    /// the slots need not remember the profile they were filled under.
    pub fn findFor(self: *DecodeCache, core: decode.profile.Profile, instr: Instr) ?decode.Hit {
        const slot = &self.table[(instr.address >> 1) & (slots - 1)];
        if (slot.hit) |hit| {
            if (slot.address == instr.address and slot.hw1 == instr.hw1 and slot.hw2 == instr.hw2) {
                self.hits += 1;
                return hit;
            }
        }
        self.misses += 1;
        const hit = decode.decodeFor(core, instr) orelse return null;
        slot.* = .{ .address = instr.address, .hw1 = instr.hw1, .hw2 = instr.hw2, .hit = hit };
        return hit;
    }
};
