//! Raising a SecureFault for a violation of the Security Extension.
//!
//! SecureFault is exception 7, with its own status register, SFSR, and its
//! own address register, SFAR. The causes are an invalid entry point from
//! Non-secure state (INVEP, a branch into Secure memory that is not an SG in
//! an NSC region), an invalid integrity signature or EXC_RETURN on an
//! exception return (INVIS, INVER), a Non-secure access to Secure memory
//! (AUVIOL), a branch to Non-secure code that did not say so (INVTRAN), and
//! the two lazy state errors (LSPERR, LSERR). An attribution violation and a
//! lazy state preservation error also latch SFAR with SFARVALID.
//!
//! It is taken like the other configurable faults: its own vector while
//! SHCSR.SECUREFAULTENA stands and it can preempt, HardFault with
//! HFSR.FORCED otherwise. Deciding that an access or a branch violates
//! attribution needs the core's security state (RA8EMU-41); this file only
//! raises what that check reports.
//!
//!   SFSR 0xE000_EDE4  SFAR 0xE000_EDE8  (Armv8-M ARM, D1.2.x)

const fault_clear = @import("fault_clear.zig");
const fault_route = @import("fault_route.zig");
const fault_take = @import("fault_take.zig");
const nvic = @import("nvic/nvic.zig");

pub const sfsr: u32 = fault_clear.sfsr;
pub const sfar: u32 = 0xE000_EDE8;

/// An SFSR cause, valued by its bit position.
pub const Cause = enum(u3) {
    invep = 0,
    invis = 1,
    inver = 2,
    auviol = 3,
    invtran = 4,
    lsperr = 5,
    lserr = 7,

    pub fn bit(self: Cause) u32 {
        return @as(u32, 1) << @backingInt(self);
    }

    /// Whether this cause reports the address it went for in SFAR.
    pub fn hasAddress(self: Cause) bool {
        return self == .auviol or self == .lsperr;
    }
};

/// SFSR.SFARVALID: SFAR holds the address of the latest violation.
pub const sfarvalid: u32 = 1 << 6;

/// Every SFSR bit that is defined. Each is write-one-to-clear, through
/// src/chip/periph/fault_clear.zig.
pub const defined: u32 = 0xFF;

/// What a SecureFault leaves in SFSR, and in SFAR when there is one.
pub const Owed = struct { sfsr: u32, address: ?u32 };

/// The status `cause` latches. `address` is used only by the causes that
/// report one; for the rest it is ignored.
pub fn latch(cause: Cause, address: u32) Owed {
    if (!cause.hasAddress()) return .{ .sfsr = cause.bit(), .address = null };
    return .{ .sfsr = cause.bit() | sfarvalid, .address = address };
}

/// Latch `cause` and take the fault raised by the instruction at `pc`.
pub fn raise(
    core: anytype,
    controller: *nvic.Nvic,
    cause: Cause,
    address: u32,
    pc: u32,
) !fault_route.Taken {
    const owed = latch(cause, address);
    const was = core.readWord(sfsr) catch 0;
    try core.writeWord(sfsr, was | owed.sfsr);
    if (owed.address) |at| try core.writeWord(sfar, at);
    return fault_take.take(core, controller, .secure_fault, pc);
}
