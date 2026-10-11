//! Taking a configurable fault once its status bits are latched.
//!
//! Every synchronous fault ends the same way: route it against SHCSR, SHPR1
//! and the execution priority, owe HFSR.FORCED if it escalated, put the PC
//! back on the faulting instruction so it is the stacked return address, and
//! enter the handler. The raisers latch their own status bits and call this.

const memmap = @import("../core/memmap.zig");
const status = @import("fault_status.zig");
const fault_route = @import("fault_route.zig");
const exec_priority = @import("exec_priority.zig");
const nvic = @import("nvic/nvic.zig");

/// Route `fault`, raised by the instruction at `pc`, and enter its handler.
pub fn take(core: anytype, controller: *nvic.Nvic, fault: status.Fault, pc: u32) !fault_route.Taken {
    const route = fault_route.route(
        fault,
        core.readWord(memmap.scb.shcsr) catch 0,
        core.readWord(memmap.scb.shpr1) catch 0,
        exec_priority.current(core, controller.running()),
    );
    if (route.escalated) {
        const hfsr = core.readWord(memmap.scb.hfsr) catch 0;
        try core.writeWord(memmap.scb.hfsr, hfsr | status.Hard.forced.bit());
    }
    try core.setRegister(.pc, pc);
    try controller.enter(core, .{ .number = route.number, .priority = route.priority });
    return route;
}
