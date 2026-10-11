//! Which System Control Block registers have a Secure and a Non-secure copy,
//! and where each copy lives in the emulator's plain-RAM PPB.
//!
//! The architecture says it register by register, in the "Attributes" line
//! of each D1.2 entry: banked between Security states, banked on a bit by
//! bit basis, or not banked. That is the whole table below, and nothing is
//! in it that was not read off a page of the Armv8-M ARM (DDI0553A.k):
//!
//!   banked          VTOR p1195, SHPR2 p1147, MMFAR p1085, CCSIDR p878,
//!                   CPACR p885
//!   bit by bit      ICSR p1025, AIRCR p862, SCR p1132, CCR p874,
//!                   SHPR1 p1145, SHPR3 p1148, SHCSR p1138, CFSR p880
//!   not banked      CPUID p890, HFSR p1021, DFSR p924, BFAR p869,
//!                   NSACR p1109
//!
//! The PPB is plain memory here, so a copy has to live at some address. The
//! Secure copy (and the only copy of an unbanked register) lives at the
//! register's own address; the Non-secure copy of a banked register lives
//! at its alias, 0x2_0000 higher. That is where firmware already writes it
//! from Secure state (VTOR_NS), so the choice keeps every existing image
//! reading what it wrote.
//!
//! A bit-by-bit register's banked bits are listed only once its page has
//! been read field by field. So far that is AIRCR (p862 to p865): PRIGROUP
//! [10:8] is the one banked field; VECTKEY/VECTKEYSTAT, ENDIANNESS, PRIS,
//! BFHFNMINS, SYSRESETREQS, SYSRESETREQ and VECTCLRACTIVE are not banked.
//! SCR (p1132 to p1133): SEVONPEND [4] and SLEEPONEXIT [1] are banked;
//! SLEEPDEEPS [3] and SLEEPDEEP [2] are not. CCR (p874 to p877): BP [18],
//! IC [17], DC [16], STKOFHFNMIGN [10], DIV_0_TRP [4], UNALIGN_TRP [3] and
//! USERSETMPEND [1] are banked; BFHFNMIGN [8] is not. ICSR (p1025 to
//! p1029): PENDSVSET [28] and PENDSVCLR [27], and PENDSTSET [26] and
//! PENDSTCLR [25] only when two SysTick timers are implemented. SHPR1 (p1145): PRI_6
//! (UsageFault) and PRI_4 (MemManage). SHPR3 (p1148): PRI_14 (PendSV), and
//! PRI_15 (SysTick) only when two SysTick timers are implemented. SHCSR
//! (p1138 to p1144): the HardFault, UsageFault, MemManage, SVCall and PendSV
//! bits, and SYSTICKACT [11] only with two SysTicks; the SecureFault,
//! BusFault, NMI and DebugMonitor bits are not. CFSR (p880): UFSR [31:16]
//! and MMFSR [7:0]; BFSR [15:8] is not. Reserved bits are left out of
//! every mask.
//!
//! A bit-by-bit register is not given an address. Its shared bits have one
//! home and its banked bits two, so a whole-word answer would be wrong for
//! one half; the answer says so and the field split is left to the register
//! that owns it.
const alias = @import("../scs_alias.zig");

pub const Banking = enum { banked, bit_by_bit, not_banked };

const Entry = struct { offset: u32, banking: Banking };

/// Offsets from the start of the SCB, 0xE000_ED00.
const table = [_]Entry{
    .{ .offset = 0x00, .banking = .not_banked }, // CPUID
    .{ .offset = 0x04, .banking = .bit_by_bit }, // ICSR
    .{ .offset = 0x08, .banking = .banked }, // VTOR
    .{ .offset = 0x0C, .banking = .bit_by_bit }, // AIRCR
    .{ .offset = 0x10, .banking = .bit_by_bit }, // SCR
    .{ .offset = 0x14, .banking = .bit_by_bit }, // CCR
    .{ .offset = 0x18, .banking = .bit_by_bit }, // SHPR1
    .{ .offset = 0x1C, .banking = .banked }, // SHPR2
    .{ .offset = 0x20, .banking = .bit_by_bit }, // SHPR3
    .{ .offset = 0x24, .banking = .bit_by_bit }, // SHCSR
    .{ .offset = 0x28, .banking = .bit_by_bit }, // CFSR
    .{ .offset = 0x2C, .banking = .not_banked }, // HFSR
    .{ .offset = 0x30, .banking = .not_banked }, // DFSR
    .{ .offset = 0x34, .banking = .banked }, // MMFAR
    .{ .offset = 0x38, .banking = .not_banked }, // BFAR
    .{ .offset = 0x80, .banking = .banked }, // CCSIDR
    .{ .offset = 0x88, .banking = .banked }, // CPACR
    .{ .offset = 0x8C, .banking = .not_banked }, // NSACR
};

/// How the word at `address` (normal window) is banked, or null when it is
/// not an SCB register this table has read up on.
pub fn banking(address: u32) ?Banking {
    if (!alias.scb.covers(address)) return null;
    const offset = address - alias.scb.first;
    for (table) |entry| {
        if (entry.offset == offset) return entry.banking;
    }
    return null;
}

/// How many SysTick timers the part has. With two, the SysTick fields of
/// SHPR3 and SHCSR are banked as well.
pub const SysTicks = enum {
    one,
    two,

    /// The variant for a part's timer count, as src/chip/core/part/part.zig gives it.
    pub fn of(count: u2) SysTicks {
        return if (count >= 2) .two else .one;
    }
};

const Split = struct {
    offset: u32,
    banked: u32,
    /// Banked only when two SysTick timers are implemented.
    systick: u32 = 0,
};

/// The banked bits of the bit-by-bit registers read so far.
const splits = [_]Split{
    .{ .offset = 0x0C, .banked = 0x0000_0700 }, // AIRCR.PRIGROUP
    .{ .offset = 0x10, .banked = 0x0000_0012 }, // SCR.SEVONPEND, SLEEPONEXIT
    .{ .offset = 0x14, .banked = 0x0007_041A }, // CCR, see the file comment
    .{ .offset = 0x04, .banked = 0x1800_0000, .systick = 0x0600_0000 }, // ICSR.PENDSV*, PENDST*
    .{ .offset = 0x18, .banked = 0x00FF_00FF }, // SHPR1.PRI_6, PRI_4
    .{ .offset = 0x20, .banked = 0x00FF_0000, .systick = 0xFF00_0000 }, // SHPR3
    .{ .offset = 0x24, .banked = 0x0025_B48D, .systick = 0x0000_0800 }, // SHCSR
    .{ .offset = 0x28, .banked = 0xFFFF_00FF }, // CFSR.UFSR, MMFSR
};

/// The bits of `address` that have a separate Non-secure copy: all of them
/// for a banked register, none for an unbanked one, the read fields for a
/// bit-by-bit one. Null when that has not been read yet.
pub fn bankedBits(address: u32, systicks: SysTicks) ?u32 {
    const kind = banking(address) orelse return null;
    return switch (kind) {
        .banked => 0xFFFF_FFFF,
        .not_banked => 0,
        .bit_by_bit => for (splits) |split| {
            if (split.offset == address - alias.scb.first) {
                break split.banked | if (systicks == .two) split.systick else 0;
            }
        } else null,
    };
}

pub const Backing = union(enum) {
    /// The one word in the PPB that holds this copy.
    word: u32,
    /// A register banked bit by bit; see the file comment.
    bit_by_bit: alias.Target,
    /// Not an SCB register the table covers.
    unknown: alias.Target,
};

/// Where the copy `target` names lives.
pub fn backing(target: alias.Target) Backing {
    const kind = banking(target.address) orelse return .{ .unknown = target };
    return switch (kind) {
        .not_banked => .{ .word = target.address },
        .bit_by_bit => .{ .bit_by_bit = target },
        .banked => .{ .word = switch (target.view) {
            .secure => target.address,
            .non_secure => target.address + alias.offset,
        } },
    };
}
