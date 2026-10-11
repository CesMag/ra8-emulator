//! Exception entry and return for `--trace-rtos` (RA8EMU-224).
//!
//! The NVIC model counts every handler it enters (`taken`) and every return
//! (`returned`), and keeps the active exceptions as a stack. Both happen
//! between instructions, so reading those counters before each instruction
//! sees every one. A return that goes straight into another handler (a tail
//! chain) moves both counters at once; it is read as the return and then
//! the entry, which is the order they happened in. Two entries between the
//! same pair of instructions show as one, the innermost.
//!
//! This file reads the model's counters and nothing else, so the
//! watcher needs nothing from the core.
const nvic = @import("ra8_chip").periph.nvic;
const rtos_trace = @import("trace.zig");

pub const Nvic = nvic.Nvic;

pub const Watcher = struct {
    controller: *const nvic.Nvic,
    taken: u64 = 0,
    returned: u64 = 0,
    /// Exceptions seen entered and not yet returned from, innermost last.
    open: [nvic.Nvic.max_nesting]u16 = undefined,
    depth: usize = 0,

    /// Start from where the controller is now, so nothing before is traced.
    pub fn start(controller: *const nvic.Nvic) Watcher {
        return .{ .controller = controller, .taken = controller.taken, .returned = controller.returned };
    }

    /// Record whatever the controller entered or returned from since the
    /// last look. A return this watcher never saw entered reads as 0.
    pub fn observe(self: *Watcher, trace: *rtos_trace.Trace, core: u1, when: u64) void {
        const now = self.controller;
        while (self.returned < now.returned) : (self.returned += 1) {
            var number: u16 = 0;
            if (self.depth > 0) {
                self.depth -= 1;
                number = self.open[self.depth];
            }
            trace.exception(core, when, .leave, number);
        }
        if (self.taken == now.taken) return;
        self.taken = now.taken;
        if (now.depth == 0) return;
        const number = now.active[now.depth - 1].number;
        if (self.depth < self.open.len) {
            self.open[self.depth] = number;
            self.depth += 1;
        }
        trace.exception(core, when, .enter, number);
    }
};

/// The architecture's name for an exception number, or null for an IRQ or
/// a reserved number, which are printed by number.
pub fn label(number: u16) ?[]const u8 {
    return switch (number) {
        1 => "Reset",
        2 => "NMI",
        3 => "HardFault",
        4 => "MemManage",
        5 => "BusFault",
        6 => "UsageFault",
        7 => "SecureFault",
        11 => "SVCall",
        12 => "DebugMonitor",
        14 => "PendSV",
        15 => "SysTick",
        else => null,
    };
}
