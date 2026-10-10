//! The debug probe side of SEGGER RTT: find the firmware's control block in
//! RAM, drain its terminal up-buffer, and surface the text.
//!
//! This owns no register window. RTT is a plain-RAM protocol, so the J-Link
//! scans target RAM for the ten-byte ID the block starts with, reads up-buffer
//! zero's ring, and stores the advanced read offset back so the firmware sees
//! the buffer emptying. That is all this file does, once per chunk boundary,
//! against the same SRAM the CPU is running out of. An RTT-logging image gets
//! its banner out of the emulator with no UART pin, exactly as it would in
//! JLinkRTTViewer.
//!
//! Ported from board_periph_rtt.c on dev, with four things that model does
//! not do.
//!
//! THE RING HAS TO BE IN RAM, AND RAM IS ALL OF IT. dev checks the
//! descriptor's sizes and offsets and never checks where the storage pointer
//! points, then reads through it and stores four bytes of read offset back
//! through it. A block caught half-initialised, with a stale or garbage
//! pointer, has the emulator reading the peripheral window and calling the
//! result firmware output, and writing into an address the firmware never
//! meant as a ring. Here the whole ring must lie in RAM a debug probe can
//! reach, which is every region the loader maps as RAM, and a candidate that
//! does not is refused and counted. That is a wider rule than `search`
//! below, deliberately: the block is what the probe hunts for and a hunt is
//! bounded by what it costs, while the ring is one pointer away from a block
//! already in hand.
//!
//! A FORGOTTEN BLOCK RE-ARMS THE SCAN. dev forgets a clobbered block by
//! zeroing the address and leaves the scan cadence where it was, which is
//! already in the past, so from then on it scans the whole RAM window on every
//! single tick for the rest of the run. Here forgetting re-arms the backoff.
//!
//! A TORN-DOWN BLOCK IS NOT DRAINED. dev validates the up-buffer count once,
//! at discovery, and never reads it again, so an image that tears its RTT
//! block down keeps being drained through a descriptor it no longer publishes.
//! Re-read every drain here.
//!
//! THE FIRST SCAN IS AT THE FIRST BOUNDARY, not sixty-four chunks in: see
//! `cadence`.
//!
//! THE UNFINISHED LINE SURVIVES, and an over-long one is not counted as a line
//! the firmware ended: see line.zig.
//!
//! NOT MODELLED, AND NOT GUESSED: down-buffers (host to target input, which
//! nothing in this tree drives), up-buffers past channel zero, and the
//! descriptor's flags word, whose blocking modes only matter to a writer that
//! fills the ring faster than the probe empties it.
const std = @import("std");

const Guest = @import("../../core/cpu/memory/guest.zig").Guest;
const memmap = @import("../../core/memmap.zig");
const block = @import("block.zig");
const text = @import("line.zig");

/// The window the scan hunts a control block in: the SRAM this tree actually
/// maps, not dev's hard-coded four megabytes. A J-Link searches the ranges it
/// is configured with rather than the whole address space, and this is that
/// range. The ring the block points at is not held to it: see `rtt_block`.
pub const search = memmap.Window{
    .base = memmap.sram_base,
    .end = memmap.sram_end,
};

/// Bytes the scan covers.
pub fn searchSize() u32 {
    return search.end - search.base;
}

/// Scan cadence and per-tick bounds. A run whose firmware never uses RTT pays
/// a handful of scans, not one per chunk.
pub const cadence = struct {
    /// Chunk boundaries before the first scan. dev waits sixty-four, which in
    /// this tree's chunking is most of a short run: an image that logs a
    /// banner and stops is never looked for there. The probe starts looking
    /// at the first boundary here, and the backoff below is what keeps a
    /// firmware with no RTT in it from paying for a scan every chunk.
    pub const first_scan: u32 = 1;
    /// Longest gap the backoff grows to.
    pub const max_gap: u32 = 1024;
    /// Bytes staged per scan sub-read.
    pub const step: u32 = 4096;
    /// Bytes drained per tick.
    pub const drain: u32 = 4096;
};

/// The drain model: what has been found, what has been taken out of it, and
/// what the run should be told.
pub const Rtt = struct {
    /// The machine whose RAM is scanned. A board built by a test without one
    /// finds nothing, which is the only way this is ever null.
    memory: ?Guest = null,
    line: text.Line = .{},
    /// The control block, once a scan has validated one.
    found: ?u32 = null,
    ticks: u32 = 0,
    next_scan: u32 = cadence.first_scan,
    scan_gap: u32 = cadence.first_scan,
    scans: u32 = 0,
    drained: u32 = 0,
    /// Blocks that went away under us: the ID stopped matching, or the
    /// firmware tore the descriptor down.
    forgotten: u32 = 0,
    /// Candidates whose ring was not in RAM, dev's missing check.
    off_ram: u32 = 0,
    /// Descriptors read mid-update, left for the next tick.
    skipped: u32 = 0,
    stage: [cadence.step + block.id.len]u8 = undefined,
    segment: [cadence.drain]u8 = undefined,

    /// One chunk boundary: scan until a block turns up, then keep it drained.
    pub fn tick(self: *Rtt) void {
        const memory = self.memory orelse return;
        self.ticks += 1;
        if (self.found == null) {
            if (self.ticks < self.next_scan) return;
            self.scan(memory);
            if (self.found == null) {
                self.backOff();
                return;
            }
        }
        self.drain(memory);
    }

    /// Stage the RAM window a step at a time, carrying an ID-length overlap so
    /// a block straddling a boundary is still matched. Only the step itself
    /// holds candidate starts: the overlap is there to complete a block that
    /// begins inside this step, and the next step owns anything beginning in
    /// it, so no candidate is examined twice.
    fn scan(self: *Rtt, memory: Guest) void {
        self.scans += 1;
        const size = searchSize();
        var offset: u32 = 0;
        while (offset < size) : (offset += cadence.step) {
            var want: u32 = cadence.step + block.id.len;
            if (offset + want > size) want = size - offset;
            if (want < block.id.len) return;
            const starts = @min(cadence.step, want - block.id.len + 1);
            const at = search.base + offset;
            memory.read(at, self.stage[0..want]) catch return;
            if (self.match(memory, at, self.stage[0..want], starts)) return;
        }
    }

    /// The first validated block in one staged window, latched.
    fn match(self: *Rtt, memory: Guest, at: u32, staged: []const u8, starts: u32) bool {
        var index: usize = 0;
        while (index < starts and index + block.id.len <= staged.len) : (index += 1) {
            if (!block.idAt(staged, index)) continue;
            const candidate = at + @as(u32, @intCast(index));
            const up = self.readUp(memory, candidate) orelse continue;
            const count = readWord(memory, candidate + block.layout.max_up) orelse continue;
            if (block.check(count, up)) |why| {
                if (why == .ring_off_ram) self.off_ram += 1;
                continue;
            }
            self.found = candidate;
            return true;
        }
        return false;
    }

    /// Take what the firmware has written since the last tick, and tell it so
    /// by storing the advanced read offset back.
    fn drain(self: *Rtt, memory: Guest) void {
        const at = self.found.?;
        if (!self.stillThere(memory, at)) return;
        const count = readWord(memory, at + block.layout.max_up) orelse return;
        const up = self.readUp(memory, at) orelse return;
        if (block.check(count, up)) |why| {
            switch (why) {
                // The firmware published a block and has taken it away again.
                .no_up_buffer, .too_many_up_buffers, .empty_ring => self.forget(),
                .ring_off_ram => {
                    self.off_ram += 1;
                    self.forget();
                },
                else => self.skipped += 1,
            }
            return;
        }
        const pending = up.pending();
        if (pending == 0) return;
        const want = @min(pending, cadence.drain);
        const got = self.take(memory, up, want);
        if (got == 0) return;
        for (self.segment[0..got]) |byte| self.line.feed(byte);
        const advanced = (up.read + got) % up.size;
        memory.writeWord(at + block.layout.up0 + block.layout.desc_read, advanced) catch return;
        self.drained += got;
    }

    /// The ring, in at most two runs around the wrap.
    fn take(self: *Rtt, memory: Guest, up: block.Up, want: u32) u32 {
        const first = up.firstRun(want);
        memory.read(up.buf + up.read, self.segment[0..first]) catch return 0;
        if (want == first) return first;
        memory.read(up.buf, self.segment[first..want]) catch return first;
        return want;
    }

    /// Up-buffer zero's descriptor as it stands right now.
    fn readUp(self: *Rtt, memory: Guest, at: u32) ?block.Up {
        _ = self;
        const up0 = at + block.layout.up0;
        return .{
            .buf = readWord(memory, up0 + block.layout.desc_buf) orelse return null,
            .size = readWord(memory, up0 + block.layout.desc_size) orelse return null,
            .write = readWord(memory, up0 + block.layout.desc_write) orelse return null,
            .read = readWord(memory, up0 + block.layout.desc_read) orelse return null,
        };
    }

    /// A warm reboot or a clobber takes the block away; the scan finds the
    /// next one.
    fn stillThere(self: *Rtt, memory: Guest, at: u32) bool {
        var head: [block.id.len]u8 = undefined;
        memory.read(at, &head) catch {
            self.forget();
            return false;
        };
        if (std.mem.eql(u8, &head, &block.id)) return true;
        self.forget();
        return false;
    }

    fn forget(self: *Rtt) void {
        self.found = null;
        self.forgotten += 1;
        self.scan_gap = cadence.first_scan;
        self.next_scan = self.ticks + self.scan_gap;
    }

    fn backOff(self: *Rtt) void {
        if (self.scan_gap < cadence.max_gap) self.scan_gap *= 2;
        self.next_scan = self.ticks + self.scan_gap;
    }

    /// Nothing to say: no block was ever found and no text came out.
    pub fn quiet(self: *const Rtt) bool {
        return self.found == null and self.line.quiet() and self.drained == 0 and self.off_ram == 0;
    }
};

fn readWord(memory: Guest, at: u32) ?u32 {
    return memory.readWord(at) catch null;
}
