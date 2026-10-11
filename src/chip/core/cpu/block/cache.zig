//! Formed blocks kept by start address (RA8EMU-405).
//!
//! `next` hands `Cpu.step` the instruction at the PC with its decode, from
//! the block it is walking when the PC is the next entry, else from the
//! block that starts at the PC, formed on a miss. A write from anywhere over
//! a marked code line drops the blocks on it (RA8EMU-407, RA8EMU-409), so a
//! block in DTCM, MRAM or SRAM is trusted as formed. A block anywhere else is
//! checked against the halfwords now in memory before each entry is handed
//! out, so rewritten code never runs stale. A null answer sends the step down its own fetch and decode,
//! which reports any fault or unknown encoding exactly as before.
const Instr = @import("../instr.zig").Instr;
const bus = @import("../bus.zig");
const decode = @import("../decode/decode.zig");
const block = @import("block.zig");
const code_lines = @import("../code_lines.zig");

/// Direct-mapped by start address; a power of two.
pub const slots: usize = 1024;

pub const BlockCache = struct {
    blocks: [slots]block.Block,
    decoded: decode.cache.DecodeCache,
    current: ?*block.Block,
    index: usize,
    /// Lines the blocks cover; pass to `code_lines.watch` while running.
    lines: code_lines.CodeLines,
    /// Blocks formed, blocks found already formed, entries whose memory
    /// had changed since they were formed, and blocks a store dropped.
    formed: u64,
    reused: u64,
    stale: u64,
    dropped: u64,

    /// Set up in place: the cache is too large to build on the stack.
    pub fn init(self: *BlockCache) void {
        for (&self.blocks) |*one| {
            one.start = 0;
            one.len = 0;
        }
        self.decoded = .{};
        self.current = null;
        self.index = 0;
        self.lines.clear();
        self.dropped = 0;
        self.formed = 0;
        self.reused = 0;
        self.stale = 0;
    }

    /// The instruction at `address` and its decode, or null to step it the
    /// slow way.
    pub fn next(self: *BlockCache, from: bus.Bus, core: decode.profile.Profile, address: u32) ?block.Entry {
        if (self.lines.dirty) self.drop();
        if (self.current) |walking| {
            if (self.index < walking.len and walking.entries[self.index].instr.address == address)
                return self.take(from, walking);
        }
        const found = &self.blocks[(address >> 1) & (slots - 1)];
        if (found.len != 0 and found.start == address) {
            self.reused += 1;
        } else {
            found.* = block.Block.form(from, &self.decoded, core, address);
            found.tracked = code_lines.covers(found.start, found.end());
            self.lines.mark(found.start, found.end());
            self.formed += 1;
        }
        self.current = found;
        self.index = 0;
        return self.take(from, found);
    }

    fn take(self: *BlockCache, from: bus.Bus, walking: *block.Block) ?block.Entry {
        if (self.index >= walking.len) return self.leave();
        const kept = walking.entries[self.index];
        if (walking.tracked) {
            self.index += 1;
            return kept;
        }
        const now = Instr.fetch(from, kept.instr.address) catch return self.leave();
        if (now.size != kept.instr.size or now.hw1 != kept.instr.hw1 or now.hw2 != kept.instr.hw2) {
            walking.len = 0;
            self.stale += 1;
            return self.leave();
        }
        self.index += 1;
        return kept;
    }

    /// Drop every block on a line a store has written since the last drop.
    fn drop(self: *BlockCache) void {
        const low = self.lines.low;
        const high = self.lines.high;
        self.lines.dirty = false;
        for (&self.blocks) |*one| {
            if (one.len == 0) continue;
            const first = code_lines.line(one.start) orelse continue;
            const last = code_lines.line(one.end() -% 1) orelse first;
            if (last < low or first > high) continue;
            one.len = 0;
            self.dropped += 1;
        }
        if (self.current) |walking| if (walking.len == 0) {
            self.current = null;
        };
    }

    fn leave(self: *BlockCache) ?block.Entry {
        self.current = null;
        return null;
    }
};
