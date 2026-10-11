//! Call stacks sampled in a served session (RA8EMU-833, part 1 of 2): a
//! stack_sampler.Sampler on a core's retire path, stamped with the board's
//! virtual time and tagged with the RTOS thread when the harness traces
//! one. The store is what the session wire's folded request reads.
//!
//! Nothing samples until `watch`; a session that never asks runs as before.
const elf = @import("ra8_board").image.elf;
const cpu_mod = @import("ra8_chip").core.cpu.cpu;
const TimeBase = @import("ra8_chip").periph.timebase.TimeBase;
const dwarf_line = @import("../dwarf_line/dwarf_line.zig");
const rtos_trace = @import("../rtos_trace.zig");
const stack_profile = @import("../stack_profile.zig");
const stack_sampler = @import("../stack_sampler.zig");
const stack_samples = @import("../stack_samples.zig");

/// One sample every this many retired instructions, unless set otherwise.
pub const default_every: u32 = 1000;

/// Large (the store keeps every sample in place): put it on the heap.
pub const Stacks = struct {
    store: stack_samples.Store = .{},
    every: u32 = default_every,
    cores: [2]?stack_sampler.Sampler = .{ null, null },

    /// Sample `cpu` as core `index`, walking its stacks with `image`'s
    /// frames and symbols. `self` and `image` outlive the sampling.
    pub fn watch(self: *Stacks, index: u1, cpu: *cpu_mod.Cpu, image: *const elf.Image, time: *const TimeBase, trace: ?*const rtos_trace.Trace) void {
        self.unwatch(index, cpu);
        self.cores[index] = .{
            .view = .{ .zig = .{ .cpu = cpu } },
            .core = index,
            .every = self.every,
            .frame = dwarf_line.section(image.*, ".debug_frame"),
            .starts = stack_profile.starts(image),
            .store = &self.store,
            .trace = trace,
            .time = time,
            .next = cpu.retire_listener,
        };
        cpu.retire_listener = self.cores[index].?.listener();
    }

    /// Stop sampling `cpu`, giving its retire path back to whoever had it.
    pub fn unwatch(self: *Stacks, index: u1, cpu: *cpu_mod.Cpu) void {
        const sampler = self.cores[index] orelse return;
        cpu.retire_listener = sampler.next;
        self.cores[index] = null;
    }

    pub fn watching(self: *const Stacks, index: u1) bool {
        return self.cores[index] != null;
    }
};
