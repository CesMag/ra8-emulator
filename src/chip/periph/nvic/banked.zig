//! SysTick and PendSV with both of their banks (RA8EMU-438).
//!
//! Both are banked between the Security states (DDI0553 B3.4): the Secure
//! copy of ICSR PENDSTSET/PENDSVSET and SHPR3 PRI_15/PRI_14 is in the word at
//! 0xE000_EDxx, the Non-secure copy at 0xE002_EDxx (RA8EMU-365). A core that
//! can reach that copy has `readNonSecure` and `writeNonSecure`; one that
//! cannot offers only the Secure copy.
const memmap = @import("../../core/memmap.zig");
const systick_bank = @import("../../core/systick_bank.zig");
const Candidate = @import("../candidate.zig").Candidate;

/// The pends in both copies, Secure first.
pub fn read(core: anytype) !systick_bank.Pends {
    const secure: systick_bank.Words = .{
        .icsr = try core.readWord(memmap.scb.icsr),
        .shpr3 = try core.readWord(memmap.scb.shpr3),
    };
    const non_secure: systick_bank.Words = if (comptime reaches(@TypeOf(core))) .{
        .icsr = try core.readNonSecure(memmap.scb.icsr),
        .shpr3 = try core.readNonSecure(memmap.scb.shpr3),
    } else .{ .icsr = 0, .shpr3 = 0 };
    // A core that reaches the Non-secure copy runs a Non-secure SysTick of
    // its own (RA8EMU-154), so SysTick is offered from both copies.
    return systick_bank.pends(secure, non_secure, true);
}

/// Fold a Non-secure PENDSVCLR: it clears itself and PENDSVSET in that copy,
/// as clear.zig does for the shared word.
pub fn fold(core: anytype) !void {
    if (comptime !reaches(@TypeOf(core))) return;
    const icsr = try core.readNonSecure(memmap.scb.icsr);
    if (icsr & icsr_pendsvclr == 0) return;
    try core.writeNonSecure(memmap.scb.icsr, icsr & ~(icsr_pendsvclr | icsr_pendsvset));
}

/// One pend as the NVIC pick weighs it.
pub fn candidate(pend: systick_bank.Pend) Candidate {
    return .{ .number = pend.number, .priority = pend.priority, .non_secure = pend.view == .non_secure };
}

/// Clear SysTick's or PendSV's pend in the Non-secure copy of ICSR.
pub fn clear(core: anytype, number: u16) !void {
    if (comptime !reaches(@TypeOf(core))) return;
    const bit: u32 = if (number == systick_bank.systick) icsr_pendstset else icsr_pendsvset;
    const icsr = try core.readNonSecure(memmap.scb.icsr);
    try core.writeNonSecure(memmap.scb.icsr, icsr & ~bit);
}

const icsr_pendstset: u32 = 1 << 26;
const icsr_pendsvset: u32 = 1 << 28;
const icsr_pendsvclr: u32 = 1 << 27;

/// Whether `Core`, or what it points at, can reach the Non-secure copy.
pub fn reaches(comptime Core: type) bool {
    const T = switch (@typeInfo(Core)) {
        .pointer => |p| p.child,
        else => Core,
    };
    if (@typeInfo(T) != .@"struct") return false;
    return @hasDecl(T, "readNonSecure") and @hasDecl(T, "writeNonSecure");
}
