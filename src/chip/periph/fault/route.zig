//! Which exception a configurable fault is taken as, and at what priority.
//!
//! MemManage, BusFault, UsageFault and SecureFault are each a configurable fault with its
//! own enable in SHCSR and its own priority byte in SHPR1. A fault that is
//! disabled, or that cannot preempt what is running because its priority is
//! no more urgent than the current execution priority, escalates to
//! HardFault and sets HFSR.FORCED (DDI0553 B3.9). The status the fault
//! latched in CFSR stays where it was either way, so the HardFault handler
//! can read what really happened.
//!
//!   SHCSR 0xE000_ED24  MEMFAULTENA [16]  BUSFAULTENA [17]  USGFAULTENA [18]
//!                      SECUREFAULTENA [19]
//!                      (DDI0553 D1.2.9)
//!   SHPR1 0xE000_ED18  PRI_4 [7:0]  PRI_5 [15:8]  PRI_6 [23:16]  PRI_7 [31:24]
//!                      (DDI0553 D1.2.10)
//!   HFSR  0xE000_ED2C  FORCED [30]  (DDI0553 D1.2.12)

const status = @import("status.zig");

pub const Fault = status.Fault;

/// HardFault, exception 3 (DDI0553 B3.6).
pub const hard_fault: u16 = 3;

/// The priority an escalated HardFault runs at. Architecturally it is -1;
/// the model's priority is unsigned, so zero is the most urgent it can say.
pub const hard_fault_priority: u8 = 0;

/// The exception number of each configurable fault (DDI0553 B3.6).
pub fn exception(fault: Fault) u16 {
    return switch (fault) {
        .mem_manage => 4,
        .bus_fault => 5,
        .usage_fault => 6,
        .secure_fault => 7,
    };
}

/// The SHCSR bit that enables each configurable fault.
pub fn enable(fault: Fault) u32 {
    return @as(u32, 1) << (16 + @as(u5, @intCast(exception(fault) - 4)));
}

/// The fault's own priority, its byte of SHPR1.
pub fn priority(fault: Fault, shpr1: u32) u8 {
    return @truncate(shpr1 >> (8 * @as(u5, @intCast(exception(fault) - 4))));
}

/// Where a fault goes.
pub const Taken = struct {
    number: u16,
    priority: u8,
    /// Escalated to HardFault, so HFSR.FORCED is owed.
    escalated: bool,
};

/// Route `fault` given SHCSR and SHPR1. `running` is the current execution
/// priority, or null when the caller cannot say; then only the enable
/// decides, which is what a fault taken from thread mode at no boosted
/// priority comes to anyway.
pub fn route(fault: Fault, shcsr: u32, shpr1: u32, running: ?u8) Taken {
    const own = priority(fault, shpr1);
    const enabled = shcsr & enable(fault) != 0;
    // Equal priority cannot preempt either: a fault that cannot be taken
    // now is escalated rather than left pending.
    const preempts = if (running) |level| own < level else true;
    if (enabled and preempts) {
        return .{ .number = exception(fault), .priority = own, .escalated = false };
    }
    return .{ .number = hard_fault, .priority = hard_fault_priority, .escalated = true };
}
