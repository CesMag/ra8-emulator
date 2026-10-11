//! A decoded block (RA8EMU-403): the straight run of instructions from one
//! address up to the first that can change control flow.
//!
//! Formation only. RA8EMU-405 runs blocks from Cpu.run behind a switch and
//! RA8EMU-404 invalidates them on writes and turns them on.
const Instr = @import("../instr.zig").Instr;
const bus = @import("../bus.zig");
const decode = @import("../decode/decode.zig");
const block_end = @import("end.zig");

/// The most instructions one block holds.
pub const cap: usize = 32;

pub const Entry = struct {
    instr: Instr,
    hit: decode.Hit,
};

pub const Block = struct {
    start: u32 = 0,
    len: usize = 0,
    /// Every line it covers is tracked, so writes over it drop it and its
    /// entries are handed out without a re-check (RA8EMU-409).
    tracked: bool = false,
    entries: [cap]Entry = undefined,

    /// Fetch and decode forward from `start` through `cache`. The block ends
    /// after an instruction `end.zig` marks, at `cap`, or before an
    /// encoding that fails to fetch or decode, which the caller then steps
    /// one at a time and faults on as it does today. It can be empty.
    pub fn form(from: bus.Bus, cache: *decode.cache.DecodeCache, core: decode.profile.Profile, start: u32) Block {
        var block: Block = .{ .start = start };
        var at = start;
        while (block.len < cap) {
            const instr = Instr.fetch(from, at) catch break;
            const hit = cache.findFor(core, instr) orelse break;
            block.entries[block.len] = .{ .instr = instr, .hit = hit };
            block.len += 1;
            if (block_end.endsBlock(instr)) break;
            at +%= instr.size;
        }
        return block;
    }

    pub fn items(self: *const Block) []const Entry {
        return self.entries[0..self.len];
    }

    /// The address after the last instruction in the block.
    pub fn end(self: *const Block) u32 {
        if (self.len == 0) return self.start;
        const last = self.entries[self.len - 1].instr;
        return last.address +% last.size;
    }
};

/// The block-end test, for callers and tests.
pub const ends = block_end.endsBlock;
