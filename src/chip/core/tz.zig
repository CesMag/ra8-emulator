//! The Secure to Non-Secure world switch: BLXNS, performed by hand.
//!
//! WHAT THE INSTRUCTION DOES. `BLXNS Rm` is Armv8-M's call into the
//! Non-Secure world: it branches to the address in Rm (bit 0 clear, which is
//! what marks the target as Non-Secure rather than Thumb), switches the core
//! to Non-Secure state, banks the stack pointer over to SP_NS, and leaves
//! FNC_RETURN in LR so the callee can come back. The RA8D2's secure boot
//! ends with exactly one of them, in `ra8_tz_secure_boot_jump_ns`, right
//! after it has written VTOR_NS and set MSP_NS from the Non-Secure vector
//! table.
//!
//! WHY IT IS NOT LEFT TO THE CPU MODEL. An Armv8.0-M CPU model does execute the
//! instruction: the branch lands, the stack banks, LR comes back 0xFEFFFFFF.
//! What it cannot do is make the target Non-Secure. Its M33 has an SAU of
//! its own, reached through the core rather than over the bus, and this
//! emulator maps the whole PPB as ordinary RAM, so every SAU register the
//! firmware programs lands in memory and the core's own SAU stays at its
//! reset state: disabled, which attributes the entire address space as
//! Secure. The core therefore arrives in Non-Secure state at an address it
//! considers Secure, and the very first instruction of the Non-Secure reset
//! handler raises a fault. On the firmware this emulator is built for, that
//! is `push {r7, lr}` at the Non-Secure reset handler and the run ends
//! there.
//!
//! WHAT IS MODELLED INSTEAD. This emulator has one flat, fully accessible
//! address space and no Secure and Non-Secure worlds to place an access in
//! (the same call src/chip/periph/sau/sau.zig records: the map is kept, attribution
//! is not enforced). In a single domain, entering the Non-Secure world *is*
//! a branch. So the site is hooked, the branch is performed here, and the
//! core never executes the BLXNS: it stays in Secure state, where every
//! address is reachable, and carries on into the Non-Secure image. Nothing
//! about the firmware's own sequence is skipped or patched.
//!
//! WHAT THIS DELIBERATELY DOES NOT DO. Not a step towards real attribution:
//! there is no state to switch to, so a Non-Secure access that should fault
//! still will not. And no SG veneer handling: an image whose Non-Secure half
//! calls back into Secure through a Non-Secure-Callable entry needs the
//! range check those veneers make to pass in a flat space, which is its own
//! seam and not this one.
const std = @import("std");

/// The secure boot routine that holds the one BLXNS. Named here rather than
/// at the call site: which function hands the world over is a fact about
/// this firmware's boot, and this is the file that knows about the switch.
pub const jump_routine = "ra8_tz_secure_boot_jump_ns";

pub const limits = struct {
    /// How much of the routine a scan will read. The real one is 212 bytes;
    /// the cap is what keeps the read on the stack and refuses a symbol
    /// whose size says it is some other, much larger function.
    pub const routine_bytes: u32 = 1024;
};

/// The Thumb encoding of BLXNS, and how far past one execution resumes.
pub const encoding = struct {
    /// One Thumb halfword: the unit a scan steps by, and the width of this
    /// instruction.
    pub const width: u32 = 2;
    /// `BLXNS Rm` is 0x4780 | (Rm << 3) | 0x04. Masking with this leaves
    /// the fixed bits, so any Rm matches.
    pub const mask: u16 = 0xFF87;
    pub const match: u16 = 0x4784;
    /// Where Rm sits once the fixed bits are masked off.
    pub const register_mask: u16 = 0x0078;
    pub const register_shift: u4 = 3;
    /// Bit 0 of the target is clear on a real BLXNS and has to be set on a
    /// program counter, which reads it as the Thumb bit.
    pub const thumb: u32 = 1;
};

/// Which register a BLXNS takes its target from, or null when the halfword
/// is some other instruction. Null is the answer that matters: it leaves a
/// halfword that merely looks like one alone.
pub fn decode(halfword: u16) ?u4 {
    if (halfword & encoding.mask != encoding.match) return null;
    return @truncate((halfword & encoding.register_mask) >> encoding.register_shift);
}

/// The offset of the first BLXNS in a stretch of code, or null when it
/// holds none.
///
/// The walk is halfword by halfword and knows nothing about instruction
/// boundaries, so in principle it could match the tail halfword of a 32-bit
/// encoding or a word of a literal pool. It is bounded to one function the
/// symbol table sized, which issues exactly one BLXNS, and the pattern it
/// looks for has 0x47 in its high byte: a register-operand branch, not a
/// value. The first match is the one taken; a second would be a different
/// function's.
pub fn findBlxns(code: []const u8) ?u32 {
    var offset: usize = 0;
    while (offset + encoding.width <= code.len) : (offset += encoding.width) {
        const halfword = std.mem.readInt(u16, code[offset..][0..2], .little);
        if (decode(halfword) != null) return @intCast(offset);
    }
    return null;
}

/// Where the Non-Secure world starts, and on what.
pub const Entry = struct {
    /// The first Non-Secure instruction, carrying the Thumb bit.
    pc: u32,
    /// The stack it runs on, or null to leave the Secure one in place.
    /// Null is not a failure: the branch is still worth taking, and the
    /// report says which stack the world was entered on.
    sp: ?u32,
    /// Where a Non-Secure function that returns comes back to. A real
    /// BLXNS leaves FNC_RETURN here and the core unstacks the Secure frame
    /// from it; in one flat space the same effect is the address after the
    /// BLXNS, so a callee that returns lands where the architecture would
    /// have put it.
    lr: u32,
};

/// What the switch does to the core: the branch, the stack and the return
/// address, worked out without touching one.
pub fn enter(target: u32, stack: ?u32, after: u32) Entry {
    return .{
        .pc = (target & ~encoding.thumb) | encoding.thumb,
        .sp = stack,
        .lr = after | encoding.thumb,
    };
}

/// What a run has to say about the seam afterwards.
///
/// An image with no secure boot in it arms nothing and says nothing. An
/// image that arms the seam says so even when the switch never happened,
/// because a boot that was meant to reach the Non-Secure world and did not
/// is the interesting outcome, not a quiet one.
pub const Worlds = struct {
    /// The BLXNS the seam is armed on, or zero when the image has none.
    armed_at: u32 = 0,
    /// How many times the world was entered.
    switched: usize = 0,
    /// Where, and on what stack: zero for a switch that kept the Secure
    /// stack because the Non-Secure vector table could not be read.
    entered_at: u32 = 0,
    stack: u32 = 0,

    pub fn quiet(self: Worlds) bool {
        return self.armed_at == 0;
    }

    /// True once the Non-Secure world actually ran.
    pub fn entered(self: Worlds) bool {
        return self.switched != 0;
    }

    pub fn record(self: *Worlds, entry: Entry) void {
        self.switched += 1;
        self.entered_at = entry.pc & ~encoding.thumb;
        self.stack = entry.sp orelse 0;
    }
};
