//! The fault status words, bit by bit: what CFSR and HFSR can say.
//!
//! CFSR at 0xE000_ED28 is three status registers in one word (DDI0553
//! D1.2.11): MMFSR in the low byte for MemManage, BFSR in the next byte for
//! BusFault, UFSR in the top half for UsageFault. HFSR at 0xE000_ED2C says
//! why a HardFault was taken (D1.2.12). Every bit in both is set by the
//! core when the fault happens and cleared by the firmware writing a one
//! to it.
//!
//! Each core has its own pair, reached through its own PPB, so a fault on
//! CPU1 never shows in CPU0's CFSR. Today the emulator sets only the
//! MemManage bits an MPU-refused access raises (src/chip/periph/mpu/) and
//! HFSR.FORCED when that fault escalates. This file is the one table every
//! later cause is set from and decoded by, so a cause is named once and a
//! handler's dump and the run report read the word the same way.

const std = @import("std");
const Bounded = @import("../../core/bounded.zig").Bounded;

/// How a store to CFSR or HFSR clears the bits it wrote ones to. Reached
/// through here so the status words and their write rule are one name.
pub const clear = @import("clear.zig");

/// Where a configurable fault is taken, and when it escalates.
pub const route = @import("route.zig");

/// Raising a BusFault for an access the bus refused.
pub const bus = @import("../bus_fault.zig");
/// The execution priority after PRIMASK and BASEPRI. src/chip/periph/exec_priority.zig.
pub const exec = @import("../exec_priority.zig");
/// Raising a UsageFault. src/chip/periph/usage_fault.zig.
pub const usage = @import("../usage_fault.zig");
/// Raising a SecureFault. src/chip/periph/secure_fault.zig.
pub const secure = @import("../secure_fault.zig");

/// A CFSR cause, valued by its bit position. Positions not listed are
/// reserved and read as zero on silicon.
pub const Cause = enum(u5) {
    // MMFSR, MemManage.
    iaccviol = 0,
    daccviol = 1,
    munstkerr = 3,
    mstkerr = 4,
    mlsperr = 5,
    mmarvalid = 7,
    // BFSR, BusFault.
    ibuserr = 8,
    preciserr = 9,
    impreciserr = 10,
    unstkerr = 11,
    stkerr = 12,
    lsperr = 13,
    bfarvalid = 15,
    // UFSR, UsageFault.
    undefinstr = 16,
    invstate = 17,
    invpc = 18,
    nocp = 19,
    stkof = 20,
    unaligned = 24,
    divbyzero = 25,

    pub fn bit(self: Cause) u32 {
        return @as(u32, 1) << @backingInt(self);
    }

    /// The fault this cause belongs to.
    pub fn fault(self: Cause) Fault {
        const at = @backingInt(self);
        if (at < 8) return .mem_manage;
        if (at < 16) return .bus_fault;
        return .usage_fault;
    }
};

pub const Fault = enum { mem_manage, bus_fault, usage_fault, secure_fault };

/// An HFSR cause, valued by its bit position.
pub const Hard = enum(u5) {
    /// A vector table read failed while taking an exception.
    vecttbl = 1,
    /// A configurable fault was disabled or outranked and escalated.
    forced = 30,
    /// A debug event arrived with halting debug off.
    debugevt = 31,

    pub fn bit(self: Hard) u32 {
        return @as(u32, 1) << @backingInt(self);
    }
};

pub const cfsr = struct {
    pub const mmfsr: u32 = 0x0000_00FF;
    pub const bfsr: u32 = 0x0000_FF00;
    pub const ufsr: u32 = 0xFFFF_0000;
    /// Every bit a cause names; the rest of the word is reserved.
    pub const defined: u32 = maskOf(Cause);
};

pub const hfsr = struct {
    pub const defined: u32 = maskOf(Hard);
};

pub const Causes = Bounded(Cause, @typeInfo(Cause).@"enum".field_names.len);
pub const HardCauses = Bounded(Hard, @typeInfo(Hard).@"enum".field_names.len);

/// The causes a CFSR word reports, lowest bit first. Reserved bits are
/// dropped rather than named.
pub fn decode(word: u32) Causes {
    var found = Causes{};
    inline for (@typeInfo(Cause).@"enum".field_values) |value| {
        const cause: Cause = @fromBackingInt(@intCast(value));
        if (word & cause.bit() != 0) found.appendAssumeCapacity(cause);
    }
    return found;
}

/// The causes an HFSR word reports, lowest bit first.
pub fn decodeHard(word: u32) HardCauses {
    var found = HardCauses{};
    inline for (@typeInfo(Hard).@"enum".field_values) |value| {
        const cause: Hard = @fromBackingInt(@intCast(value));
        if (word & cause.bit() != 0) found.appendAssumeCapacity(cause);
    }
    return found;
}

/// The three fault status words as a run left them.
pub const Words = struct { cfsr: u32 = 0, hfsr: u32 = 0, sfsr: u32 = 0 };

/// One report line naming every cause the words hold, and nothing when all
/// three are clear, so a run that never faulted prints what it always did.
pub fn line(out: anytype, words: Words) !void {
    if (words.cfsr | words.hfsr | words.sfsr == 0) return;
    try out.print("faults: CFSR 0x{X:0>8}", .{words.cfsr});
    for (decode(words.cfsr).constSlice()) |cause| try out.print(" {s}", .{@tagName(cause)});
    try out.print(", HFSR 0x{X:0>8}", .{words.hfsr});
    for (decodeHard(words.hfsr).constSlice()) |cause| try out.print(" {s}", .{@tagName(cause)});
    try out.print(", SFSR 0x{X:0>8}\n", .{words.sfsr});
}

fn maskOf(comptime E: type) u32 {
    var mask: u32 = 0;
    inline for (@typeInfo(E).@"enum".field_values) |value| mask |= @as(u32, 1) << value;
    return mask;
}
