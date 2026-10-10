//! ADC_B: the 16-bit converter, and the scan group that has to be enabled
//! before a start means anything.
//!
//! The block sits at 0x4033_8000 with a 0x2224 window (ra8_adc_b_regs.h, FSP
//! R_ADC_B0_Type). A polling read drives it in three steps: programme an
//! ADCHCRn slot with the physical source and the scan group, kick the group
//! with ADSTR[group].ADST, then poll ADSR.ADACT0 until the unit is idle and
//! read the result out of ADDR[slot]. A conversion is instantaneous here, so
//! the poll completes on its first read.
//!
//! The arithmetic of a slot, which source it names and what that source
//! reports, lives next door in scan.zig. This file owns the window, the
//! scan machine and what the run is told afterwards.
//!
//! Ported from board_periph_adc.c on dev, with four things that model does
//! not do.
//!
//! A SCAN GROUP HAS TO BE ENABLED. dev converts whichever slots name the
//! started group whether or not ADSGER, the scan-group enable it declares in
//! its own register map and then never reads, has that group's bit set. So an
//! image that programmes its channels and starts a scan without enrolling the
//! group reads real-looking results on dev and reads nothing back on silicon.
//! Here the start is refused and counted, and no result register moves.
//!
//! RESULTS AND STATUS ARE WHAT THE CONVERTER PUT THERE. dev's write path
//! drops any store anywhere in the window, ADSR and ADDR and ADEXDR included,
//! so firmware can write its own conversion result and read it back as
//! though the block produced it. Refused and counted here, the pattern
//! already taken for CETCR, SRAMESR and the CANFD status registers.
//!
//! THE START BIT DOES NOT STAY SET. dev latches the ADST it was given, so
//! ADSTR reads back as a scan in progress forever while ADSR in the same
//! breath reports the unit idle. The two cannot both be true. The scan
//! completes inside the store here, so ADST is spent by the time the store
//! returns, and a driver that polls either register gets the same answer.
//!
//! A NARROW WRITE ONLY TOUCHES THE BYTES IT NAMES. dev's `reg[off / 4] =
//! value` makes a byte store to ADSTR.ADST wipe the three bytes above it, and
//! a halfword store into an ADCHCRn slot wipe the source field.
//!
//! AN UNPROGRAMMED SLOT STILL READS AS GROUP 0 CHANNEL 0, which is dev's
//! behaviour and is kept: ADCHCRn powers up at zero, and zero is a legal
//! enrolment. So a scan of group 0 converts all twenty-four slots, where a
//! scan of any other group converts only the slots that name it. No header
//! in this tree gives a per-slot enable bit, and inventing one would be a
//! guess about silicon rather than a fix, so the count is reported instead
//! and an image that wants one channel gives it a group of its own.
//!
//! KEPT FROM DEV DELIBERATELY: the driver convention that a normal channel's
//! virtual slot index is also its ADDR index; the single ADC0 scan-end event
//! for every group, since no header in this tree gives a per-group one; and
//! the raise on a group with no channel enrolled, which is dev's behaviour
//! and not obviously wrong, though the empty scan is counted so a run that
//! never enrolled anything says so.
//!
//! THE SCAN-END INTERRUPT ENABLE lives in src/chip/periph/adc/intr.zig: ADINTCR
//! (+0x005C) decides whether a finished scan raises anything at all, so an
//! image the HAL brought up, which writes ADINTCR = 0 in `ra8_adc_init`,
//! converts and reports and owes the core nothing. The event used to be
//! raised whatever that register held.
//!
//! NOT MODELLED AND NOT GUESSED: ADTRGENR and every hardware trigger,
//! the A/D error and overflow status bits, ADSR for units other than 0, and
//! the sampling-time and gain registers. They are shadowed so a read-modify-
//! write survives, and never read.
const std = @import("std");
const Bounded = @import("../../core/bounded.zig").Bounded;
const periph = @import("../registry.zig");
pub const scan = @import("scan.zig");
pub const intr = @import("intr.zig");

/// The scan-end interrupt enable, reached as `adc.interrupt` the way the
/// other split blocks in this tree re-export their halves.
pub const interrupt = intr;
/// The TSN factory calibration words the die-temperature line pairs with.
pub const tsn_cal = @import("tsn_cal.zig");

/// The window. The Non-secure alias is folded onto this base by the bus.
pub const win_base: u32 = 0x4033_8000;
pub const win_span: u32 = 0x2224;

/// The registers this model interprets. Everything else in the window is
/// shadowed.
pub const off = struct {
    pub const adsger: u32 = 0x0048;
    pub const adintcr: u32 = intr.off_adintcr;
    pub const adsgdcr0: u32 = 0x0200;
    pub const adchcr0: u32 = 0x0600;
    pub const addopcrc0: u32 = 0x060C;
    pub const adstr0: u32 = 0x0C20;
    pub const adstopr: u32 = 0x0C60;
    pub const adsr: u32 = 0x0C80;
    pub const addr0: u32 = 0x2000;
    pub const adexdr0: u32 = 0x2180;
};

/// Array dimensions, mirroring ra8_adc_b_limits_t.
pub const limits = struct {
    pub const slots: usize = 24;
    pub const results: usize = 23;
    pub const ext_results: usize = 23;
    pub const groups: usize = 9;
    /// ADCHCRn and ADDOPCRCn share a 16-byte per-slot stride.
    pub const slot_stride: u32 = 0x10;
    pub const word_stride: u32 = 4;
};

pub const field = struct {
    /// ADSTR[n].ADST, the software start.
    pub const adst: u32 = 0x0000_0001;
    /// ADSR.ADACT0, unit 0 busy. Never set: a conversion is instantaneous.
    pub const adact0: u32 = 0x0000_0001;
};

/// The ADC0 scan-complete (ADI) event, from the RA8D2 ELC table (HUM Ch 19).
pub const event = struct {
    pub const scan_end: u16 = 0x09C;
};

pub const Due = Bounded(u16, 1);

const words: usize = win_span / 4;

/// The modelled converter.
pub const Adc = struct {
    reg: [words]u32 = @splat(0),
    /// Scans that actually ran.
    scans: u32 = 0,
    /// Channels converted across every scan.
    converted: u32 = 0,
    /// The last code written into a result register.
    last_code: u16 = 0,
    /// Starts refused because the group was not enabled in ADSGER.
    refused_disabled: u32 = 0,
    /// Stores into a result or status register, refused.
    faked: u32 = 0,
    /// Scans that found no slot enrolled in the group.
    empty: u32 = 0,
    /// Converted slots with no result register behind them.
    unbacked: u32 = 0,
    /// Force-stops taken through ADSTOPR.
    stops: u32 = 0,
    /// Scans that finished with ADINTCR clear, so no event was raised.
    masked: u32 = 0,
    due_scan: bool = false,

    pub fn init() Adc {
        return .{};
    }

    pub fn quiet(self: *const Adc) bool {
        return self.scans == 0 and self.refused_disabled == 0 and self.faked == 0 and
            self.stops == 0;
    }

    /// The event this boundary earned, offered once.
    pub fn dueEvents(self: *Adc) Due {
        var due = Due{};
        if (self.due_scan) {
            self.due_scan = false;
            due.appendAssumeCapacity(event.scan_end);
        }
        return due;
    }

    pub fn read(self: *Adc, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        if (offset >= win_span) return 0;
        const word = self.reg[offset / 4];
        // ADACT0 is held clear: the conversion finished inside the store that
        // started it, so the unit is never busy by the time anyone looks.
        const value = if (offset & ~@as(u32, 3) == off.adsr) word & ~field.adact0 else word;
        return part(value, offset % 4, width);
    }

    pub fn write(self: *Adc, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        if (offset >= win_span) return;
        const aligned = offset & ~@as(u32, 3);
        if (self.controllerOwned(aligned)) {
            self.faked +%= 1;
            return;
        }
        if (aligned == off.adstopr) {
            self.forceStop();
            return;
        }
        const merged = merge(self.reg[offset / 4], offset % 4, width, value);
        if (self.startedGroup(aligned, merged)) |group| {
            // The start bit is spent whatever comes of it, so what the
            // register keeps is the rest of the word.
            self.reg[offset / 4] = merged & ~field.adst;
            self.start(group);
            return;
        }
        self.reg[offset / 4] = merged;
    }

    /// ADSR and both result banks answer for the converter, so a store into
    /// one is firmware writing down an answer nothing produced.
    fn controllerOwned(self: *const Adc, aligned: u32) bool {
        _ = self;
        if (aligned == off.adsr) return true;
        if (inBank(aligned, off.addr0, limits.results)) return true;
        return inBank(aligned, off.adexdr0, limits.ext_results);
    }

    /// The group a store is trying to start, if it is one.
    fn startedGroup(self: *const Adc, aligned: u32, merged: u32) ?u32 {
        _ = self;
        if (!inBank(aligned, off.adstr0, limits.groups)) return null;
        if (merged & field.adst == 0) return null;
        return (aligned - off.adstr0) / limits.word_stride;
    }

    /// A start. The group has to be enabled first; an unenrolled one converts
    /// nothing on silicon however well its channels are programmed.
    fn start(self: *Adc, group: u32) void {
        if (self.reg[off.adsger / 4] & (@as(u32, 1) << @intCast(group)) == 0) {
            self.refused_disabled +%= 1;
            return;
        }
        const converted = self.convert(group);
        if (converted == 0) self.empty +%= 1;
        self.converted +%= converted;
        self.scans +%= 1;
        // The conversion happened either way; only the interrupt is at stake.
        if (intr.enabled(self.reg[off.adintcr / 4])) {
            self.due_scan = true;
        } else {
            self.masked +%= 1;
        }
    }

    /// Every slot enrolled in the group converts. A pin channel reports to
    /// ADDR[slot], an on-chip source to ADEXDR[source - base].
    fn convert(self: *Adc, group: u32) u32 {
        var converted: u32 = 0;
        const diagval = self.reg[(off.adsgdcr0 + group * limits.word_stride) / 4];
        for (0..limits.slots) |index| {
            const slot = scan.Slot.decode(self.slotWord(off.adchcr0, index));
            if (slot.group != group) continue;
            if (slot.internal()) {
                const ext_index = slot.extIndex();
                if (ext_index >= limits.ext_results) {
                    self.unbacked +%= 1;
                    continue;
                }
                self.deliver(off.adexdr0, ext_index, scan.internalValue(slot.source, diagval));
            } else {
                if (index >= limits.results) {
                    self.unbacked +%= 1;
                    continue;
                }
                const format = scan.format(self.slotWord(off.addopcrc0, index));
                self.deliver(off.addr0, @intCast(index), format.midscale());
            }
            converted += 1;
        }
        return converted;
    }

    /// Put a code in a result register. DATA[15:0] is the whole of it; the
    /// error bits above it stay clear, because nothing here can fault.
    fn deliver(self: *Adc, bank: u32, index: u32, code: u16) void {
        self.reg[(bank + index * limits.word_stride) / 4] = @as(u32, code) & scan.result.data;
        self.last_code = code;
    }

    /// ADSTOPR: every armed group gives up its start bit. dev declares the
    /// register and then only shadows it.
    fn forceStop(self: *Adc) void {
        for (0..limits.groups) |group| {
            const word = (off.adstr0 + @as(u32, @intCast(group)) * limits.word_stride) / 4;
            self.reg[word] &= ~field.adst;
        }
        self.stops +%= 1;
    }

    fn slotWord(self: *const Adc, bank: u32, index: usize) u32 {
        return self.reg[(bank + @as(u32, @intCast(index)) * limits.slot_stride) / 4];
    }

    pub fn block(self: *Adc) periph.Block {
        return .{
            .name = "ADC_B",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

/// Whether an aligned offset lands in a bank of `count` word-wide registers.
fn inBank(aligned: u32, bank: u32, count: usize) bool {
    return aligned >= bank and aligned < bank + @as(u32, @intCast(count)) * limits.word_stride;
}

/// The part of a 32-bit register a narrow access names.
fn part(value: u32, byte_offset: u32, width: u3) u32 {
    if (width >= 4) return value;
    const shift: u5 = @intCast(byte_offset * 8);
    const shifted = value >> shift;
    return if (width == 1) shifted & 0xFF else shifted & 0xFFFF;
}

/// Fold a narrow write into a 32-bit register, leaving the bytes the access
/// does not name where they were.
fn merge(current: u32, byte_offset: u32, width: u3, value: u32) u32 {
    if (width >= 4) return value;
    const shift: u5 = @intCast(byte_offset * 8);
    const bits: u32 = if (width == 1) 0xFF else 0xFFFF;
    const window: u32 = bits << shift;
    return (current & ~window) | ((value & bits) << shift);
}

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Adc = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Adc = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}

/// The address of one ADCHCRn slot, so a test or a later slice does not do
/// the arithmetic itself.
pub fn slotAddress(index: usize) u32 {
    return win_base + off.adchcr0 + @as(u32, @intCast(index)) * limits.slot_stride;
}

/// The address of one ADDOPCRCn slot.
pub fn formatAddress(index: usize) u32 {
    return win_base + off.addopcrc0 + @as(u32, @intCast(index)) * limits.slot_stride;
}

/// The address of one group's software-start register.
pub fn startAddress(group: usize) u32 {
    return win_base + off.adstr0 + @as(u32, @intCast(group)) * limits.word_stride;
}

/// The address of one group's self-diagnosis control register.
pub fn diagAddress(group: usize) u32 {
    return win_base + off.adsgdcr0 + @as(u32, @intCast(group)) * limits.word_stride;
}

/// The address of one ordinary result register.
pub fn resultAddress(index: usize) u32 {
    return win_base + off.addr0 + @as(u32, @intCast(index)) * limits.word_stride;
}

/// The address of one extended-analog result register.
pub fn extResultAddress(index: usize) u32 {
    return win_base + off.adexdr0 + @as(u32, @intCast(index)) * limits.word_stride;
}
