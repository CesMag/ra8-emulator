//! Which soak event a latched fault is (RA8EMU-186, slice 2b).
//!
//! The core sets CFSR, HFSR and SFSR when it takes a fault, and they stay
//! set until the firmware writes ones back. A soak run reads them at each
//! boundary, so a fault ends the run at the stretch it happened in. The
//! most specific cause wins: a stack-limit overflow is named before the
//! UsageFault it raises, and a configurable fault before the HardFault it
//! escalated to. A handler that clears its fault inside the same stretch
//! hides it from the soak; the report's faults line has the same view.
const fault_status = @import("../../chip/periph/fault_status.zig");
const memmap = @import("../../chip/core/memmap.zig");
const Kind = @import("soak.zig").Kind;

/// SFSR, the SecureFault status word (DDI0553 D1.2.226).
pub const sfsr_address: u32 = 0xE000_EDE4;
/// The Non-secure copy of a banked SCB word sits this far above it.
pub const ns_offset: u32 = 0x2_0000;
/// The CFSR bits each security state keeps its own copy of: MMFSR, UFSR.
pub const cfsr_banked: u32 = 0xFFFF_00FF;

/// The event the words name, or null when all three are clear.
pub fn kind(latched: fault_status.Words) ?Kind {
    const cfsr = latched.cfsr;
    if (cfsr & fault_status.Cause.stkof.bit() != 0) return .stack_overflow;
    if (cfsr & fault_status.cfsr.mmfsr != 0) return .mem_manage;
    if (cfsr & fault_status.cfsr.bfsr != 0) return .bus_fault;
    if (cfsr & fault_status.cfsr.ufsr != 0) return .usage_fault;
    if (latched.sfsr != 0) return .secure_fault;
    if (latched.hfsr != 0) return .hard_fault;
    return null;
}

/// The three words as the Secure bank holds them, with a Non-secure
/// fault's banked CFSR bits folded in, the way the run report reads them.
/// `memory` is anything with `readWord(address) !u32`; `land` maps an SCB
/// address to where the backend keeps it. An unreadable word reads clear.
pub fn words(memory: anytype, land: *const fn (u32) ?u32) fault_status.Words {
    const peek = struct {
        fn at(mem: @TypeOf(memory), to: *const fn (u32) ?u32, address: u32) u32 {
            const where = to(address) orelse return 0;
            return mem.readWord(where) catch 0;
        }
    }.at;
    const cfsr_ns = peek(memory, land, memmap.scb.cfsr + ns_offset) & cfsr_banked;
    return .{
        .cfsr = peek(memory, land, memmap.scb.cfsr) | cfsr_ns,
        .hfsr = peek(memory, land, memmap.scb.hfsr),
        .sfsr = peek(memory, land, sfsr_address),
    };
}
