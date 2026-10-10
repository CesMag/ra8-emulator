//! The register map of the ELC window, and what an access of each width names
//! inside it.
//!
//! Split out of `src/chip/periph/elc/elc.zig`, which owns the generators, the link
//! table and the counters. This file owns the map alone: which register a word
//! holds, which lanes of that word the register actually occupies, and which
//! lanes are reserved.
//!
//! THE REGISTERS ARE NOT ALL WORDS, AND THE WINDOW IS MOSTLY RESERVED SPACE
//! (HUM Ch 19 p 817..836, ra8_elc_regs.h):
//!
//!   0x000  ELCR     8b in byte 0        the global enable, ELCON b7
//!   0x004  ELSEGRn  8b in byte 0        software event generators, stride 4
//!   0x020  ELSR[n]  16b in the low half the source event a slot takes, stride 4
//!   0x100  ELCSARx  32b                 security attribution, stored only
//!   0x110  ELCPARx  32b                 privilege attribution, stored only
//!
//! ELSR IS SIXTEEN BITS AND ELS IS TEN OF THEM, SO THE HIGH BITS OF AN EVENT
//! NUMBER LIVE IN THE SECOND BYTE. `elc.zig` used to switch on the raw byte
//! offset of an access and ignore its width, and the offset it switched on was
//! the whole stride, so every byte of a slot's word was the slot: a store of
//! the high byte at ELSR+1, the way a driver spells `ELS |= 0x100` when it
//! only has the top bits to set, landed as the LOW byte instead. Event 0x120
//! linked that way became event 0x001, a read-back of the same byte answered
//! the low byte and agreed, and the run reported a programmed link that took
//! the wrong event and never conducted the right one.
//!
//! THE SAME SLOPPINESS RAN THE OTHER WAY ON THE GENERATORS. ELSEGRn is one
//! byte, and the three bytes above it are reserved, but each of them decoded
//! to the generator: a stray byte store at +0x006 ran the trigger sequence and
//! could raise a software event silicon would never have raised. A store that
//! names only reserved lanes is nothing here now, not a trigger and not a
//! refusal, because that is what it is on the part.
const lanes = @import("../lanes.zig");
const route = @import("route.zig");

/// ELC geometry (FSP R_ELC_Type, size 0x11C at 0x4020_1000).
pub const win_base: u32 = 0x4020_1000;
pub const win_span: u32 = 0x11C;

/// Register byte offsets inside the window (ra8_elc_regs.h).
pub const off = struct {
    pub const elcr: u32 = 0x000;
    pub const elsegr: u32 = 0x004;
    pub const elsegr_stride: u32 = 0x004;
    pub const elsr: u32 = 0x020;
    pub const elsr_stride: u32 = 0x004;
    pub const elcsara: u32 = 0x100;
    pub const elcpara: u32 = 0x110;
};

/// How many of each the RA8D2 has.
pub const generators: usize = 4;
pub const links: usize = route.slots;
/// Attribution registers: three security words then three privilege words.
pub const attributions: usize = 6;
/// Each attribution group is three consecutive words.
pub const attribution_group: u32 = 3;

/// Which register a word in the window holds.
pub const Reg = union(enum) {
    control,
    generator: usize,
    link: usize,
    attribution: usize,
};

/// The register the word at `word` holds, or null for a reserved word.
pub fn decode(word: u32) ?Reg {
    if (word == off.elcr) return .control;
    if (word >= off.elsegr and word < off.elsegr + off.elsegr_stride * generators) {
        return .{ .generator = (word - off.elsegr) / off.elsegr_stride };
    }
    if (word >= off.elsr and word < off.elsr + off.elsr_stride * links) {
        return .{ .link = (word - off.elsr) / off.elsr_stride };
    }
    const group = attribution_group * 4;
    if (word >= off.elcsara and word < off.elcsara + group) {
        return .{ .attribution = (word - off.elcsara) / 4 };
    }
    if (word >= off.elcpara and word < off.elcpara + group) {
        return .{ .attribution = attribution_group + (word - off.elcpara) / 4 };
    }
    return null;
}

/// The bits of its word a register occupies. Everything else in the word is
/// reserved: it reads zero and a store into it does nothing.
pub fn occupied(reg: Reg) u32 {
    return switch (reg) {
        .control, .generator => 0xFF,
        .link => 0xFFFF,
        .attribution => ~@as(u32, 0),
    };
}

/// Whether an access of `width` starting at byte `at` reaches the register at
/// all, rather than only the reserved lanes beside it.
pub fn reaches(reg: Reg, at: u32, width: u3) bool {
    return lanes.named(at, width) & occupied(reg) != 0;
}
