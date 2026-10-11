//! Raising a BusFault for an access the bus refused.
//!
//! A load or store the bus cannot complete is a precise data BusFault:
//! BFSR.PRECISERR, with BFARVALID and BFAR holding the address it went for.
//! A refused instruction fetch is IBUSERR and leaves BFAR alone, because the
//! faulting PC already says where (DDI0553 D1.2.11, D1.2.6). The fault is
//! then taken like any configurable one: its own vector while
//! SHCSR.BUSFAULTENA stands and it can preempt what is running, HardFault
//! with HFSR.FORCED otherwise. src/chip/periph/fault/route.zig decides which.
//!
//! A precise fault stacks the faulting instruction as the return address, so
//! a handler that fixes the cause and returns retries the access.
//!
//!   BFAR 0xE000_ED38 (DDI0553 D1.2.6)

const memmap = @import("../core/memmap.zig");
const status = @import("fault/status.zig");
const fault_route = @import("fault/route.zig");
const fault_take = @import("fault/take.zig");
const nvic = @import("nvic/nvic.zig");

pub const bfar: u32 = 0xE000_ED38;

/// What a run that raises BusFaults did with them, for the caller to read.
pub const Tally = struct {
    raised: u32 = 0,
    escalated: u32 = 0,
};

/// What the refused access was.
pub const Kind = enum { read, write, fetch };

/// What the fault puts in CFSR and BFAR.
pub const Latch = struct {
    cfsr: u32,
    /// The address for BFAR, or null when the fault leaves it alone.
    address: ?u32,
};

pub fn latch(kind: Kind, address: u32) Latch {
    return switch (kind) {
        .read, .write => .{
            .cfsr = status.Cause.preciserr.bit() | status.Cause.bfarvalid.bit(),
            .address = address,
        },
        .fetch => .{ .cfsr = status.Cause.ibuserr.bit(), .address = null },
    };
}

/// Latch the status, route the fault and enter its handler, with `pc` the
/// faulting instruction. Returns where it went.
pub fn raise(
    core: anytype,
    controller: *nvic.Nvic,
    kind: Kind,
    address: u32,
    pc: u32,
) !fault_route.Taken {
    const owed = latch(kind, address);
    const cfsr = core.readWord(memmap.scb.cfsr) catch 0;
    try core.writeWord(memmap.scb.cfsr, cfsr | owed.cfsr);
    if (owed.address) |at| try core.writeWord(bfar, at);
    return fault_take.take(core, controller, .bus_fault, pc);
}
