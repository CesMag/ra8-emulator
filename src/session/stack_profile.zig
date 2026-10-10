//! The call stacks a `--profile-folded` run samples (RA8EMU-971, slice 1 of
//! RA8EMU-955): a stack_sampler.Sampler on CPU0's retire path, in front of
//! whatever listened there before, filling the profile table's store.
//!
//! The run builds its core inside boot.start and lends it through
//! boot.Wiring.core, so the sampler is made on the first instruction the
//! core retires, once that pointer is there. Frames are named and their
//! functions found from the image's symbols; the walk uses its .debug_frame
//! where that covers the pc, else the r7 frame records (RA8EMU-956).
//!
//! CPU1 (RA8EMU-972) is built before the run starts, so its sampler is
//! armed when the run lends CPU0, in front of whatever listened on CPU1,
//! and names its frames from CPU1's own image.
const std = @import("std");
const elf = @import("../board/image/elf.zig");
const cpu_mod = @import("ra8_chip").core.cpu.cpu;
const dwarf_line = @import("dwarf_line.zig");
const profile = @import("profile.zig");
const rtos_trace = @import("rtos_trace.zig");
const stack_samples = @import("stack_samples.zig");
const stack_sampler = @import("stack_sampler.zig");
const stack_walk = @import("stack_walk.zig");
const symbols = @import("symbols.zig");

pub const Run = struct {
    image: elf.Image,
    second_image: ?elf.Image = null,
    /// Null when nothing asked for samples: the run is wired as before.
    store: ?*stack_samples.Store,
    every: u32,
    clock: *const u64,
    trace: ?*const rtos_trace.Trace,
    next: ?cpu_mod.RetireListener = null,
    /// The core, lent by the run before reset and taken back after.
    core: ?*cpu_mod.Cpu = null,
    sampler: ?stack_sampler.Sampler = null,
    second: ?stack_sampler.Sampler = null,

    /// Sample when `table` carries a store, every `period(budget)`th
    /// instruction, stamped from `clock` and tagged from `trace`.
    pub fn of(table: ?*profile.Table, image: elf.Image, budget: u64, clock: *const u64, trace: ?*const rtos_trace.Trace) Run {
        const store = if (table) |found| found.samples else null;
        const second = if (table) |found| found.second else null;
        return .{ .image = image, .second_image = second, .store = store, .every = period(budget), .clock = clock, .trace = trace };
    }

    /// The listener the core gets: this in front of `next`, or `next`
    /// alone when there is nothing to sample.
    pub fn listener(self: *Run, next: ?cpu_mod.RetireListener) ?cpu_mod.RetireListener {
        if (self.store == null) return next;
        self.next = next;
        return .{ .context = self, .instructionFn = instruction };
    }

    /// Where the run lends CPU0, or null when nothing samples. `cpu1`, when
    /// the run has one, gets its sampler here, the run being in place.
    pub fn lend(self: *Run, cpu1: ?*cpu_mod.Cpu) ?*?*cpu_mod.Cpu {
        if (self.store == null) return null;
        if (cpu1) |core| {
            const image = if (self.second_image) |*found| found else &self.image;
            self.second = self.samplerOn(core, 1, image, core.retire_listener);
            core.retire_listener = self.second.?.listener();
        }
        return &self.core;
    }

    fn instruction(context: *anyopaque, address: u32) void {
        const self: *Run = @ptrCast(@alignCast(context));
        const core = self.core orelse {
            if (self.next) |chained| chained.instruction(address);
            return;
        };
        if (self.sampler == null or self.sampler.?.view.zig.cpu != core) self.sampler = self.samplerOn(core, 0, &self.image, self.next);
        self.sampler.?.listener().instruction(address);
    }

    fn samplerOn(self: *const Run, core: *cpu_mod.Cpu, index: u1, image: *const elf.Image, next: ?cpu_mod.RetireListener) stack_sampler.Sampler {
        return .{
            .view = .{ .zig = .{ .cpu = core } },
            .core = index,
            .every = self.every,
            .frame = dwarf_line.section(image.*, ".debug_frame"),
            .starts = starts(image),
            .store = self.store.?,
            .trace = self.trace,
            .clock = self.clock,
            .next = next,
        };
    }
};

/// Spread a bounded run's samples evenly over the store: one every
/// budget / slots instructions, at least every one.
pub fn period(budget: u64) u32 {
    const spread = @max(budget / stack_samples.limits.samples, 1);
    return @intCast(@min(spread, std.math.maxInt(u32)));
}

/// Function starts out of `image`'s symbols; `image` must outlive them.
pub fn starts(image: *const elf.Image) stack_walk.Starts {
    return .{ .context = image, .startFn = startOf };
}

/// Frame names out of `image`'s symbols; `image` must outlive them.
pub fn names(image: *const elf.Image) stack_samples.Names {
    return .{ .context = image, .nameFn = nameOf };
}

fn startOf(context: *const anyopaque, address: u32) ?u32 {
    const image: *const elf.Image = @ptrCast(@alignCast(context));
    const found = symbols.inside(image.*, address) orelse return null;
    return address - found.offset;
}

fn nameOf(context: *const anyopaque, address: u32) ?[]const u8 {
    const image: *const elf.Image = @ptrCast(@alignCast(context));
    const found = symbols.inside(image.*, address) orelse return null;
    return found.name;
}
