//! Per-function execution counts collected by the optional instruction hook.
const std = @import("std");
const elf = @import("ra8_board").image.elf;
const symbols = @import("symbols.zig");
const stack_samples = @import("stack/samples.zig");

pub const limits = struct {
    pub const functions: usize = 256;
    pub const ranges: usize = 2048;
    pub const listed: usize = 10;
};

pub const Site = struct { address: u32, instructions: u64 = 0, cycles: u64 = 0 };

pub const Table = struct {
    image: elf.Image,
    sites: [limits.functions]Site = undefined,
    used: usize = 0,
    missed: u64 = 0,
    extents: [limits.ranges]symbols.Extent = undefined,
    extent_count: usize = 0,
    /// Call stacks sampled on the retire path, when --profile-folded asked
    /// for them (RA8EMU-971); the folded file writes these when it has any.
    samples: ?*stack_samples.Store = null,
    /// CPU1's image when its stacks are sampled too, naming the cpu1 rows
    /// (RA8EMU-972); CPU0's image names them otherwise.
    second: ?elf.Image = null,

    /// Build the function lookup once before execution.
    pub fn prepare(self: *Table) void {
        self.extent_count = symbols.functionExtents(self.image, &self.extents);
        std.mem.sort(symbols.Extent, self.extents[0..self.extent_count], {}, extentLessThan);
    }

    /// Count one retired instruction against its containing function.
    pub fn instruction(self: *Table, pc: u32) void {
        const address = self.functionAt(pc) orelse {
            self.missed += 1;
            return;
        };
        self.add(address, 1, 1);
    }

    fn functionAt(self: *const Table, pc: u32) ?u32 {
        var low: usize = 0;
        var high = self.extent_count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.extents[middle].address <= pc) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        var index = low;
        while (index > 0) {
            index -= 1;
            const extent = self.extents[index];
            if (pc < extent.address +% extent.size) return extent.address;
        }
        return null;
    }

    fn extentLessThan(_: void, left: symbols.Extent, right: symbols.Extent) bool {
        return left.address < right.address;
    }

    /// Add an instruction and its virtual CPU-work charge. Profile cycles are
    /// deliberately one per retired instruction, not the board-clock cycles a
    /// timed run reports after scaling.
    pub fn add(self: *Table, address: u32, instructions: u64, cycles: u64) void {
        for (self.sites[0..self.used]) |*site| {
            if (site.address == address) {
                site.instructions += instructions;
                site.cycles += cycles;
                return;
            }
        }
        if (self.used == self.sites.len) {
            self.missed += instructions;
            return;
        }
        self.sites[self.used] = .{ .address = address, .instructions = instructions, .cycles = cycles };
        self.used += 1;
    }

    /// Copy and rank the function rows without mutating the live table.
    pub fn ranked(self: *const Table, into: *[limits.functions]Site) []Site {
        @memcpy(into[0..self.used], self.sites[0..self.used]);
        const out = into[0..self.used];
        // An image with no sized function leaves the table empty (RA8EMU-1143).
        if (out.len < 2) return out;
        for (1..out.len) |index| {
            var at = index;
            while (at > 0 and out[at].cycles > out[at - 1].cycles) : (at -= 1) {
                std.mem.swap(Site, &out[at], &out[at - 1]);
            }
        }
        return out;
    }
};
