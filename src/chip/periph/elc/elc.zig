//! ELC: the event link controller, which lets one event trigger a peripheral
//! without the CPU in the middle.
//!
//! A peripheral on this part raises a numbered event. The ICU decides which
//! NVIC line that event drives (src/chip/periph/icu/icu.zig); the ELC decides which
//! *peripheral* it drives, so an ADC conversion can start a DMA transfer or a
//! timer can start an ADC with no interrupt taken at all. It also owns the
//! only way firmware has to raise an event itself: the four software event
//! generators, ELSEGR0..3, which produce ELC_SWEVT0..3.
//!
//!   ELCR     (+0x000, 8b)  ELCON b7: the global enable for the whole block
//!   ELSEGRn  (+0x004, 8b, stride 4) WI b7, WE b6, SEG b0: software events
//!   ELSR[n]  (+0x020, 16b, stride 4) ELS [9:0]: the event peripheral n takes
//!   ELCSARx  (+0x100/4/8, 32b) security attribution, stored, not enforced
//!   ELCPARx  (+0x110/4/8, 32b) privilege attribution, stored, not enforced
//!
//! NOTHING WAS PORTED FROM dev, BECAUSE dev NEVER MODELLED THIS BLOCK. The C
//! tree carries inc/ra8_elc_regs.h and ten blocks that talk about ELC events
//! (adc, canfd, dmac, dtc, ipc, npu, rtc, sci, timer, ulpt), and no
//! board_periph_elc.c. So every ELC register there falls through to the
//! sparse register file, which remembers what was written: a firmware runs
//! the three-step ELSEGR0 sequence, reads 0x41 back, and believes it fired a
//! software event, while no event exists and nothing downstream ever runs.
//! The register layout here is ra8_elc_regs.h and HUM Ch 19 p 817..836.
//!
//! The map itself, and which lanes of a word each register occupies, is
//! src/chip/periph/elc/regs.zig; this file is the behaviour behind it.
const std = @import("std");
const Bounded = @import("../../core/bounded.zig").Bounded;
const periph = @import("../registry.zig");
const lanes = @import("../lanes.zig");
const regs = @import("regs.zig");
/// The link table lives next door; re-exported so a caller that has the
/// block also has the slot vocabulary.
pub const route = @import("route.zig");

/// Geometry, offsets and counts live with the map, and are re-exported so a
/// caller that has the block does not have to reach past it.
pub const win_base = regs.win_base;
pub const win_span = regs.win_span;
pub const off = regs.off;
pub const generators = regs.generators;
pub const links = regs.links;
pub const attributions = regs.attributions;

/// Field masks.
pub const field = struct {
    /// ELCR.ELCON b7: with this clear the block conducts nothing.
    pub const elcon: u8 = 0x80;
    /// ELSEGRn.WI b7: write inhibit. A write that sets it is discarded whole.
    pub const wi: u8 = 0x80;
    /// ELSEGRn.WE b6: write enable for SEG. Has to be set by an earlier write.
    pub const we: u8 = 0x40;
    /// ELSEGRn.SEG b0: generate the software event. Self-clearing.
    pub const seg: u8 = 0x01;
    /// ELSR.ELS [9:0]: the source event this peripheral slot listens for.
    pub const els: u16 = 0x03FF;
};

/// ELC_SWEVT0 is event 0x0CC (HUM Ch 19 Table 19.3), and the other three
/// follow it, so ELSEGRn generates event 0x0CC + n.
pub const swevt_base: u16 = 0x0CC;

pub fn softwareEvent(index: usize) u16 {
    return swevt_base + @as(u16, @intCast(index));
}

/// Why a trigger write generated nothing. Every one of these reads as success
/// on a sparse register file, which is the whole reason they are counted.
pub const Refusal = enum {
    /// The write set WI, so silicon discarded it without looking further.
    inhibited,
    /// SEG was written without WE armed by an earlier write.
    unarmed,
    /// ELCR.ELCON is clear, so the block is off.
    disabled,
};

/// Software events generated this boundary, drained by the board.
pub const Due = Bounded(u16, generators);

/// The link table, the generators, and the counters behind the report line.
pub const Elc = struct {
    elcr: u8 = 0,
    /// The live WE bit of each generator. WI reads back set, so it is not
    /// stored: it is a write-side gate, not a state bit.
    armed: [generators]bool = @splat(false),
    /// The ELSR slots and what has reached them (src/chip/periph/elc/route.zig).
    table: route.Table = .{},
    attribution: [attributions]u32 = @splat(0),
    pending: Due = .{},
    /// Software events actually generated.
    generated: u32 = 0,
    /// Trigger writes refused, by reason.
    inhibited: u32 = 0,
    unarmed: u32 = 0,
    disabled: u32 = 0,

    pub fn init() Elc {
        return .{};
    }

    /// A run that never touched the block stays out of the report.
    pub fn quiet(self: *const Elc) bool {
        return self.generated == 0 and self.refused() == 0 and self.table.quiet();
    }

    pub fn refused(self: *const Elc) u32 {
        return self.inhibited + self.unarmed + self.disabled;
    }

    /// Whether ELCR.ELCON is set. Nothing conducts while it is not.
    pub fn enabled(self: *const Elc) bool {
        return self.elcr & field.elcon != 0;
    }

    /// How many peripheral slots have a source event programmed.
    pub fn linkCount(self: *const Elc) u32 {
        return self.table.programmed();
    }

    /// The first peripheral slot linked to `event`, or null. Several slots may
    /// take the same source, so this answers "is anything listening" rather
    /// than standing in for the whole set; `table.takers` answers the set.
    pub fn target(self: *const Elc, event: u16) ?usize {
        return self.table.firstTaker(event);
    }

    /// Offer one event to the link table. The board calls this for EVERY
    /// event it raises, not just the four this block generates: on silicon a
    /// peripheral event reaches the ICU and the ELC at the same time, and
    /// which one acts on it is the firmware's choice, not the event's.
    ///
    /// The answer is deliberately not "it ran": what sits behind slot n is
    /// HUM Table 19.2 and is not in this tree, so a conducted event is
    /// counted at the slot and stops there. What is worth having anyway is
    /// the gate: with ELCON clear a linked event conducts NOTHING, and every
    /// register involved still reads back exactly as it would working.
    pub fn conduct(self: *Elc, event: u16) route.Arrival {
        return self.table.offer(event, self.enabled());
    }

    /// The software events generated since the last drain. The board raises
    /// each into the ICU at the chunk boundary, the same seam the serial
    /// block's interrupts go through.
    pub fn takeEvents(self: *Elc) Due {
        const due = self.pending;
        self.pending = .{};
        return due;
    }

    /// A read of any width: the word the access lands in, cut to the lanes it
    /// names. A lane the register does not occupy reads zero, because on the
    /// part it is reserved space and not the register beside it.
    pub fn read(self: *Elc, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        const reg = regs.decode(lanes.word(offset)) orelse return 0;
        return lanes.part(self.wordValue(reg), lanes.lane(offset), width);
    }

    /// A store of any width, folded into the word it lands in so the lanes it
    /// does not name keep what they had. ELS is ten bits across two, so the
    /// byte store at ELSR+1 that carries the top of an event number reaches
    /// the top of the register and not the bottom.
    pub fn write(self: *Elc, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        const reg = regs.decode(lanes.word(offset)) orelse return;
        const at = lanes.lane(offset);
        // Reserved lanes only. Nothing happens on the part, so nothing happens
        // here: not a trigger, not a stored value, and not a refusal either.
        if (!regs.reaches(reg, at, width)) return;
        const next = lanes.merge(self.wordValue(reg), at, width, value) & regs.occupied(reg);
        switch (reg) {
            .control => self.elcr = @truncate(next),
            .generator => |index| self.writeGenerator(index, @truncate(next)),
            .link => |index| self.table.latch(index, @truncate(next)),
            .attribution => |index| self.attribution[index] = next,
        }
    }

    /// What a whole word in the window reads as, before it is cut to width.
    fn wordValue(self: *const Elc, reg: regs.Reg) u32 {
        return switch (reg) {
            .control => self.elcr,
            .generator => |index| self.readGenerator(index),
            .link => |index| self.table.els[index],
            .attribution => |index| self.attribution[index],
        };
    }

    /// WI reads back set, so a driver reading the register before writing it
    /// sees a write-inhibited generator, which is what it is. SEG is
    /// self-clearing and never reads back as one.
    fn readGenerator(self: *const Elc, index: usize) u32 {
        return field.wi | (if (self.armed[index]) field.we else 0);
    }

    /// The three-step sequence, as bits rather than as a step counter:
    /// 0x00 clears WE, 0x40 arms it, 0x41 fires. A write that sets WI is
    /// discarded whole (that is what the bit means), and SEG only takes when
    /// an earlier write already armed WE, so the single 0x41 store a driver
    /// reaches for first generates nothing on silicon. FSP writes all three
    /// (ELC_ELSEGRN_STEP1..3 in r_elc.c) for exactly this reason.
    fn writeGenerator(self: *Elc, index: usize, value: u8) void {
        if (value & field.wi != 0) {
            self.inhibited +%= 1;
            return;
        }
        const was_armed = self.armed[index];
        self.armed[index] = value & field.we != 0;
        if (value & field.seg == 0) return;
        if (!was_armed or !self.armed[index]) {
            self.unarmed +%= 1;
            return;
        }
        self.generate(index);
    }

    /// Fire software event index, if the block is switched on at all. The
    /// generator disarms afterwards, so each event costs its own sequence.
    fn generate(self: *Elc, index: usize) void {
        self.armed[index] = false;
        if (!self.enabled()) {
            self.disabled +%= 1;
            return;
        }
        self.generated +%= 1;
        self.pending.append(softwareEvent(index)) catch {};
    }

    pub fn block(self: *Elc) periph.Block {
        return .{
            .name = "ELC event links",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Elc = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Elc = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}

/// The address of one ELSEGR generator, so a test or a later slice does not
/// redo the arithmetic.
pub fn generatorAddress(index: usize) u32 {
    return win_base + off.elsegr + off.elsegr_stride * @as(u32, @intCast(index));
}

/// The address of one ELSR peripheral slot.
pub fn linkAddress(index: usize) u32 {
    return win_base + off.elsr + off.elsr_stride * @as(u32, @intCast(index));
}
