//! Call stacks sampled on the retire path (RA8EMU-953, slice 2 of
//! RA8EMU-831): every Nth instruction a core retires, walk its stack and
//! keep it in a stack_samples.Store, tagged with the core, the thread the
//! RTOS tracer last saw switched in on that core, and the virtual time.
//!
//! The first instruction is sampled, then every `every`th. Registers are
//! as the instruction leaves them, so the innermost frame is the pc the
//! core goes on to. Memory is read through the core view, whose reads
//! peek and so take nothing from a FIFO (RA8EMU-938).
const cpu_mod = @import("ra8_chip").core.cpu.cpu;
const core_view = @import("core_view.zig");
const rtos_trace = @import("rtos_trace.zig");
const stack_samples = @import("stack_samples.zig");
const stack_walk = @import("stack_walk.zig");
const unwind = @import("unwind/unwind.zig");

pub const Sampler = struct {
    view: core_view.View,
    core: u1,
    every: u32,
    /// The image's .debug_frame; empty walks the frame records only.
    frame: []const u8,
    starts: ?stack_walk.Starts = null,
    store: *stack_samples.Store,
    trace: ?*const rtos_trace.Trace = null,
    /// Virtual time, borrowed.
    clock: *const u64,
    /// Whoever was listening before, told first.
    next: ?cpu_mod.RetireListener = null,
    left: u32 = 0,
    /// Samples lost because the core's registers could not be read.
    missed: u64 = 0,

    pub fn listener(self: *Sampler) cpu_mod.RetireListener {
        return .{ .context = self, .instructionFn = instruction };
    }

    fn instruction(context: *anyopaque, address: u32) void {
        const self: *Sampler = @ptrCast(@alignCast(context));
        if (self.next) |chained| chained.instruction(address);
        if (self.left > 1) {
            self.left -= 1;
            return;
        }
        self.left = @max(self.every, 1);
        self.sample();
    }

    /// Take one sample now.
    pub fn sample(self: *Sampler) void {
        const registers = unwind.registersOf(self.view) catch return self.lose();
        const psp = self.view.register(.psp) catch return self.lose();
        var stack: [stack_samples.limits.depth]u32 = undefined;
        const count = stack_walk.stackOf(self.frame, registers, psp, self.view, self.starts, &stack);
        self.store.push(self.core, self.thread(), self.clock.*, stack[0..count]);
    }

    fn thread(self: *const Sampler) u32 {
        const trace = self.trace orelse return 0;
        return trace.current[self.core] orelse 0;
    }

    fn lose(self: *Sampler) void {
        self.missed += 1;
    }
};
