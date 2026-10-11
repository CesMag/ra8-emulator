//! The ICU event-link table: how a peripheral event becomes an NVIC line.
//!
//! On this part a peripheral does not own an interrupt line. It raises a
//! numbered event, and the Interrupt Controller Unit decides which of its 96
//! NVIC lines that event drives: IELSR[n].IELS holds the event number line n
//! listens for, and firmware writes it there (`ra8_isr_register` /
//! `ra8_icu_route`) before it enables the line. Until this file existed the
//! Zig tree had no path from a block to an interrupt at all: src/chip/periph/sci/sci.zig
//! landed with its transmit and receive interrupts deliberately left out,
//! because there was nothing to raise them into, so an interrupt-driven
//! `ra8_sci_write` printed nothing and waited forever on a flag its handler
//! was supposed to set. Ported from the ICU half of board_periph.c on dev.
//!
//!   IELSR[0..95] (+0x6300, 32-bit each, one per NVIC line)
//!     IELS[9:0]  the event this line listens for, 0 = unlinked
//!     IR    [16] the latched interrupt status flag, WRITE ZERO to clear
//!     DTCE  [24] DTC activation: the slot hands its event to the DTC
//!
//! An access carries a width, and IELSR is a word whose three fields sit in
//! three different bytes of it: IELS at the bottom, IR in byte 2, DTCE in
//! byte 3. A byte or halfword access is served through src/chip/periph/lanes.zig,
//! the same rule the SCI, PORT and ELC blocks already apply.
//!
//! Only IELSR is registered on the bus. The rest of the ICU (IRQCR, the NMI
//! block, the wake-up masks, SELSR) is nobody's yet, and the sparse register
//! file answers a poll of an unmodelled register better than a block that
//! flatly returns zero for it, so the block claims the table and no more.
const memmap = @import("../../core/memmap.zig");
const periph = @import("../registry.zig");
const lanes = @import("../lanes.zig");
pub const irqcr = @import("irqcr.zig");
/// Host-driven pin edges and the ISEL/IRQMD test they pass (RA8EMU-375).
pub const pin_irq = @import("pin_irq.zig");

/// INTSELR: which core each event interrupts (src/chip/periph/icu/intsel.zig).
pub const intsel = @import("intsel.zig");
/// NMIER, NMICLR, NMISR and WUPEN0/1 (src/chip/periph/icu/nmi.zig).
pub const nmi = @import("nmi.zig");

/// R_ICU geometry (ra8_icu_regs.h): the block is at 0x4000_6000 and the
/// event-link table sits 0x6300 into it.
pub const icu_base: u32 = 0x4000_6000;
pub const off_ielsr: u32 = 0x6300;
pub const slots: usize = 96;
pub const win_base: u32 = icu_base + off_ielsr;
pub const win_span: u32 = @intCast(slots * 4);

/// IELSR fields (HUM Ch 14.2.17 p 547).
pub const field = struct {
    /// IELS[9:0]: the event number this line listens for. Zero is no link.
    pub const iels: u32 = 0x0000_03FF;
    /// IR[16]: the latched status flag. Cleared by writing ZERO, not one.
    pub const ir: u32 = 0x0001_0000;
    /// DTCE[24]: DTC activation enable. src/chip/periph/dtc/dtc.zig reads it.
    pub const dtce: u32 = 0x0100_0000;
    /// Every bit the register occupies. The rest of the word is reserved: it
    /// reads zero and a store into it is kept nowhere.
    pub const occupied: u32 = iels | ir | dtce;
};

/// The event-link table and the counters behind the end-of-run line.
pub const Icu = struct {
    links: [slots]u32 = @splat(0),
    /// Events raised by a block that some slot was listening for.
    raised: u64 = 0,
    /// Events raised that no slot listens for. Silicon drops these too; they
    /// are counted because an unrouted event is almost always a firmware bug.
    unlinked: u64 = 0,
    /// NVIC lines pended from a fresh event.
    pends: u64 = 0,
    /// NVIC lines pended again because IR was still latched at a boundary.
    repends: u64 = 0,
    /// IRQCRa/IRQCRb, the external-IRQ pins' own control bytes. They live
    /// here rather than on the board because the rule the manual puts on
    /// them is a question about this table: a pin may only be rewritten
    /// while nothing routes its event.
    pins: irqcr.Irqcr = .{},
    /// INTSELR, which core each event interrupts. Held here because the
    /// router that will read it is this table's raise.
    select: intsel.Intsel = .{},
    nmi: nmi.Nmi = .{},
    /// ICU1's event-link table. ICU0 and ICU1 share one address and each
    /// core reaches only its own (HUM Rev 1.30 14.2, p 526), so a bus access
    /// from CPU1 lands here and one from CPU0 lands in `links`. Nothing
    /// raises into this table yet.
    cpu1: [slots]u32 = @splat(0),
    /// Whose access the bus is serving, pointed at the board's bus. Null
    /// leaves every access on ICU0, which is what a single-core run and the
    /// unit tests want.
    issuer: ?*const periph.Issuer = null,

    pub fn init() Icu {
        return .{};
    }

    /// An untouched unit stays out of the end-of-run report.
    pub fn quiet(self: *const Icu) bool {
        return self.raised == 0 and self.unlinked == 0;
    }

    /// The slot listening for `event`, or null. One slot owns a given event,
    /// so the first match wins, the same rule dev's scan uses. IELS = 0 means
    /// the slot is unlinked, so event zero never matches anything.
    pub fn slotFor(self: *const Icu, event: u16) ?usize {
        return slotIn(&self.links, event);
    }

    /// The slot that activates the DTC for `event`: one linked to it with
    /// DTCE set. A slot can link the same event with DTCE clear, which is an
    /// ordinary CPU interrupt and none of the controller's business, so this
    /// keeps scanning rather than filtering slotFor's answer after the fact.
    pub fn dtcSlotFor(self: *const Icu, event: u16) ?usize {
        return dtcSlotIn(&self.links, event);
    }

    /// The same, in the table of the core `issuer` names.
    pub fn dtcSlotOn(self: *Icu, issuer: periph.Issuer, event: u16) ?usize {
        return dtcSlotIn(self.tableFor(issuer), event);
    }

    fn dtcSlotIn(table: *const [slots]u32, event: u16) ?usize {
        if (event == 0) return null;
        for (table.*, 0..) |link, index| {
            if (link & field.iels != event) continue;
            if (link & field.dtce != 0) return index;
        }
        return null;
    }

    /// Take a slot's DTCE down. The controller does this when a descriptor
    /// runs out (HUM Ch 18 Figure 18.5 p 801), so the next time that event
    /// fires the CPU takes the interrupt instead of the DTC moving nothing.
    pub fn clearDtceOn(self: *Icu, issuer: periph.Issuer, slot: usize) void {
        self.tableFor(issuer)[slot] &= ~field.dtce;
    }

    pub fn latched(self: *const Icu, slot: usize) bool {
        return self.links[slot] & field.ir != 0;
    }

    /// A peripheral event fired: latch IR on the slot linked to it and pend
    /// that NVIC line. IR is a flag rather than a count, so an event raised
    /// again while the flag is still up latches nothing new.
    pub fn raise(self: *Icu, core: anytype, event: u16) !void {
        return self.raiseOn(.cpu0, core, event);
    }

    /// The same, on the ICU of the core `issuer` names, pending `core`,
    /// which must be that core: ICU1's lines are CPU1's NVIC inputs.
    pub fn raiseOn(self: *Icu, issuer: periph.Issuer, core: anytype, event: u16) !void {
        const table = self.tableFor(issuer);
        const slot = slotIn(table, event) orelse {
            self.unlinked += 1;
            return;
        };
        self.raised += 1;
        if (table[slot] & field.ir != 0) return;
        table[slot] |= field.ir;
        try pend(core, slot);
        self.pends += 1;
    }

    /// Re-pend every line whose IR is still latched. The NVIC input is level
    /// driven from IR (HUM Ch 14.2.17), so a handler that returns without
    /// clearing the flag is entered again immediately. Call it at the chunk
    /// boundary, before the controller picks.
    pub fn repend(self: *Icu, core: anytype) !void {
        return self.rependOn(.cpu0, core);
    }

    /// The same, for the ICU of the core `issuer` names.
    pub fn rependOn(self: *Icu, issuer: periph.Issuer, core: anytype) !void {
        for (self.tableFor(issuer).*, 0..) |link, slot| {
            if (link & field.ir == 0) continue;
            if (try isPending(core, slot)) continue;
            try pend(core, slot);
            self.repends += 1;
        }
    }

    /// Take every latched IR down without touching the links. A system reset
    /// clears IELSR outright on silicon; this tree keeps peripheral state
    /// across a reboot, so clearing the flags is the part that matters: a line
    /// still latched would be re-pended into a firmware that has not put its
    /// vector table back yet.
    pub fn clearLatches(self: *Icu) void {
        for (&self.links) |*link| link.* &= ~field.ir;
        for (&self.cpu1) |*link| link.* &= ~field.ir;
    }

    /// A read is served from the IELSR word the access lands in and then cut
    /// to the byte lanes the width names, so a byte poll of the flag at +2
    /// answers IR rather than the bottom of the event number.
    pub fn read(self: *Icu, address: u32, width: u3) u32 {
        return readTable(&self.links, address, width);
    }

    /// The table the core in front of the bus reaches.
    pub fn tableFor(self: *Icu, issuer: periph.Issuer) *[slots]u32 {
        return switch (issuer) {
            .cpu0 => &self.links,
            .cpu1 => &self.cpu1,
        };
    }

    fn current(self: *Icu) *[slots]u32 {
        const issuer = self.issuer orelse return &self.links;
        return self.tableFor(issuer.*);
    }

    /// IR is WRITE-ZERO-to-clear: a written 0 takes the latched flag down and
    /// a written 1 leaves it standing. Every other bit takes the written
    /// value. This is the polarity dev had inverted (its issue #170): a driver
    /// that ORs a 1 into IR to "clear" it clears nothing on silicon, and the
    /// re-pend above then re-enters the handler forever, which is the storm
    /// the bench hit while the emulator ran the same image clean.
    /// A narrow store is merged into the word first, so the lanes it does not
    /// name keep what they had: the byte store at +2 that takes IR down is
    /// the way a bitfield write reaches this register, and it must not carry
    /// away the event number sitting in the bytes below it.
    pub fn write(self: *Icu, address: u32, width: u3, value: u32) void {
        writeTable(&self.links, address, width, value);
    }

    pub fn block(self: *Icu) periph.Block {
        return .{
            .name = "ICU event links",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }

    /// Whether some line is listening for this IRQ channel's event right
    /// now. The pin file cannot answer this; only the table can.
    pub fn pinRouted(self: *const Icu, channel: usize) bool {
        return self.slotFor(irqcr.eventFor(channel)) != null;
    }

    /// The IRQCRa/IRQCRb window. A store is handed the live routed answer,
    /// so unrouting the event before reconfiguring the pin is quiet.
    /// INTSELR and the NMI/wake-up words: the ICU windows outside IELSR.
    pub fn sideBlocks(self: *Icu) [2]periph.Block {
        return .{ self.select.block(), self.nmi.block() };
    }

    pub fn pinsBlock(self: *Icu) periph.Block {
        return .{
            .name = "ICU IRQ pins",
            .base = icu_base,
            .size = irqcr.win_span,
            .context = self,
            .readFn = pinsReadThunk,
            .writeFn = pinsWriteThunk,
        };
    }
};

/// The address of one IELSR slot, so a test or a later slice does not have to
/// do the arithmetic itself.
pub fn slotAddress(slot: usize) u32 {
    return win_base + 4 * @as(u32, @intCast(slot));
}

/// The exception number an ICU line vectors through. Slot n is IRQn, and the
/// architecture numbers IRQ0 as exception 16.
pub fn exceptionFor(slot: usize) u16 {
    return @intCast(16 + slot);
}

fn slotAt(address: u32) ?usize {
    if (address < win_base or address >= win_base + win_span) return null;
    return (address - win_base) / 4;
}

/// Pend an ICU line in the NVIC. The PPB is plain RAM in this emulator, so the
/// ICU sets the ISPR bit and src/chip/periph/nvic/nvic.zig picks it up at the same chunk
/// boundary.
///
/// The pend is unconditional, which is the one place this diverges from dev.
/// dev keeps its own ISER shadow and drops the pend when the line is disabled,
/// so an event that arrives a moment before the firmware enables its line is
/// lost for good. Here IR stays latched and the NVIC masks ISPR with ISER when
/// it picks, so enabling the line afterwards takes the interrupt, which is what
/// a level-driven IR does on silicon.
fn pend(core: anytype, slot: usize) !void {
    const address = pendingWord(slot);
    try core.writeWord(address, (try core.readWord(address)) | pendingBit(slot));
}

fn isPending(core: anytype, slot: usize) !bool {
    return (try core.readWord(pendingWord(slot))) & pendingBit(slot) != 0;
}

fn pendingWord(slot: usize) u32 {
    return memmap.nvic.ispr + 4 * (@as(u32, @intCast(slot)) / 32);
}

fn pendingBit(slot: usize) u32 {
    return @as(u32, 1) << @intCast(slot % 32);
}

/// The slot of `table` listening for `event`, or null. Event zero is no
/// link, so it never matches.
pub fn slotIn(table: *const [slots]u32, event: u16) ?usize {
    if (event == 0) return null;
    for (table, 0..) |link, index| {
        if (link & field.iels == event) return index;
    }
    return null;
}

fn readTable(table: *const [slots]u32, address: u32, width: u3) u32 {
    const slot = slotAt(address) orelse return 0;
    const word = table[slot] & field.occupied;
    return lanes.part(word, lanes.lane(address - win_base), width);
}

fn writeTable(table: *[slots]u32, address: u32, width: u3, value: u32) void {
    const slot = slotAt(address) orelse return;
    const was = table[slot];
    const next = lanes.merge(was, lanes.lane(address - win_base), width, value) & field.occupied;
    const keep: u32 = if (next & field.ir != 0) was & field.ir else 0;
    table[slot] = (next & ~field.ir) | keep;
}

/// The bus window picks the table by whose access it is serving.
fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Icu = @ptrCast(@alignCast(context));
    return readTable(self.current(), address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Icu = @ptrCast(@alignCast(context));
    writeTable(self.current(), address, width, value);
}

fn pinsReadThunk(context: *anyopaque, address: u32, width: u3) u32 {
    _ = width;
    const self: *Icu = @ptrCast(@alignCast(context));
    return self.pins.read(address -% icu_base);
}

/// A wide store at the top of the window reaches several pins, and each of
/// them gets its own routed answer, because the rule is per channel.
fn pinsWriteThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Icu = @ptrCast(@alignCast(context));
    const first = address -% icu_base;
    var step: u32 = 0;
    while (step < width) : (step += 1) {
        const offset = first + step;
        const channel = irqcr.channelAt(offset) orelse continue;
        const byte: u8 = @truncate(value >> @intCast(step * 8));
        self.pins.store(offset, byte, self.pinRouted(channel));
    }
}
