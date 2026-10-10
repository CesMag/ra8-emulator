//! SRAM controller: the ECC decoder self-test and the error status it latches.
//!
//! The control window sits at 0x4000_2000 (ra8_sram_regs.h, ra8_sram.c). Four
//! banks each carry a one-byte SRAMCRn at 0x10 + 4*bank, and the errors they
//! find land in the 16-bit SRAMESR at 0x40, two slots per bank: slot 0 is the
//! corrected single-bit error, slot 1 the uncorrectable double-bit one. The
//! address that faulted is parked in SRAMEAR[bank][slot] from 0x50, and a
//! write to SRAMESCLR at 0x48 clears whichever slots its mask names.
//!
//! On-chip SRAM is host memory here, not an MMIO hook, so the emulator never
//! sees the corrupted syndrome go in and cannot tell a one-bit fault from a
//! two-bit one. Both slots for the bank are latched together. That is dev's
//! own modelling decision and it is kept: it is enough for ra8_sram_self_test
//! to report a caught fault from either injection, which is the detection,
//! reporting and clear plumbing the demo is there to prove.
//!
//! Ported from board_periph_sram.c on dev, with two things that model does
//! not do.
//!
//! SRAMESR IS WHAT THE DECODER FOUND, NOT A REGISTER FIRMWARE FILLS IN. dev
//! takes a store to SRAMESR and drops the value straight into the status
//! word, so an image can write 0x0003 and read back two caught errors on a
//! bank whose self-test never ran. That is the whole claim a fault-injection
//! demo exists to make, provable on dev without injecting anything. Here a
//! store to SRAMESR raises nothing: it is refused and counted, the way POEG
//! refuses a store to PIDF. The flags are set by the self-test and by
//! inject(), the seam a real fault source comes in through, and cleared by
//! SRAMESCLR, which is the only write on this block that moves them.
//!
//! THE SELF-TEST IS THREE PHASES, NOT ONE EDGE. dev's own file comment names
//! the sequence ra8_sram_self_test drives per bank: write (0x08), then bypass
//! (0x80), then verify (0x1C), with the data line corrupted while in bypass.
//! Its code only watches the last edge, so a bank driven straight to bypass
//! and then verify, never having run the write phase that puts the bad
//! syndrome in, latches an error it never earned. Here the bank walks the
//! three phases in order and a verify that did not follow a write-then-bypass
//! latches nothing.
//!
//! NOT MODELLED, AND NOT GUESSED: SRAMPRCR's key and protect bits. The real
//! controller refuses a SRAMCRn write while the register is locked, and no
//! header for this part is in this tree to say which key value opens it, so
//! guessing one would turn a lock nothing here can check into a lock every
//! image fails. SRAMPRCR, SRAMWTSC and SRAMECCRGNn are shadowed, so a
//! read-modify-write of them survives, and never interpreted. A narrow access
//! only touches the bytes it names, which is the discipline every block here
//! follows; with four banks the status word never reaches its high byte, so
//! no image can tell the difference today.
const std = @import("std");
const periph = @import("../registry.zig");
const prot = @import("lock.zig");

/// SRAMPRCR and the registers its key guards, re-exported so a caller that
/// has the controller has the lock too.
pub const protection = prot;

/// SRAM-controller geometry (ra8_sram_regs.h).
pub const win_base: u32 = 0x4000_2000;
pub const win_span: u32 = 0x100;

/// The registers this model interprets. Everything else in the window is
/// shadowed.
pub const off_cr0: u32 = 0x10;
pub const off_esr: u32 = 0x40;
pub const off_esclr: u32 = 0x48;
pub const off_ear0: u32 = 0x50;

pub const bank_count: usize = 4;
pub const slots_per_bank: usize = 2;
pub const cr_stride: u32 = 4;
pub const ear_slot_stride: u32 = 4;
pub const ear_bank_stride: u32 = ear_slot_stride * @as(u32, slots_per_bank);

/// SRAMCRn values the self-test drives, in the order it drives them
/// (HUM Ch 58.3.4, named in board_periph_sram.c on dev).
pub const phase = struct {
    pub const write: u8 = 0x08;
    pub const bypass: u8 = 0x80;
    pub const verify: u8 = 0x1C;
};

/// Which ECC error a slot stands for.
pub const Slot = enum {
    /// Slot 0: single-bit, corrected by the decoder.
    corrected,
    /// Slot 1: double-bit, uncorrectable, the NMI case on silicon.
    uncorrectable,

    pub fn index(self: Slot) u32 {
        return switch (self) {
            .corrected => 0,
            .uncorrectable => 1,
        };
    }
};

/// Where each bank's data window starts, so a latched SRAMEAR carries a
/// plausible fault address rather than zero.
const bank_data_offset: [bank_count]u32 = .{
    0x0000_0000, // SRAM0 @ 0x2200_0000
    0x0008_0000, // SRAM1 @ 0x2208_0000
    0x0010_0000, // SRAM2 @ 0x2210_0000
    0x0018_0000, // SRAM3 @ 0x2218_0000
};

/// How far through write -> bypass -> verify a bank has walked. Only a verify
/// that completes the sequence latches.
const Walk = enum { idle, wrote, bypassed };

const shadow_words: usize = win_span / 4;

pub const Sram = struct {
    /// SRAMESR, the live status word. Two bits per bank.
    esr: u16 = 0,
    walk: [bank_count]Walk = @splat(.idle),
    /// The rest of the window: SRAMPRCR, SRAMWTSC, the CR bytes themselves
    /// and the ECC region registers. Kept so a read-modify-write survives,
    /// never interpreted. SRAMEAR lives here too, written by a latch.
    shadow: [shadow_words]u32 = @splat(0),
    latches: u32 = 0,
    /// Stores to SRAMESR that tried to raise a flag firmware cannot raise.
    faked: u32 = 0,
    /// SRAMPRCR, and whether the configuration registers are open to a
    /// store at all.
    lock: prot.Lock = .{},

    pub fn init() Sram {
        return .{};
    }

    pub fn quiet(self: *const Sram) bool {
        return self.latches == 0 and self.faked == 0 and self.esr == 0 and
            self.lock.quiet();
    }

    pub fn flagged(self: *const Sram, bank: usize, slot: Slot) bool {
        return self.esr & bit(bank, slot) != 0;
    }

    /// A real fault source raises one slot on one bank. Nothing inside this
    /// file can do it from a register store: the decoder finds these, and
    /// this is the seam it comes in through once the memory side can see a
    /// corrupted syndrome go past.
    pub fn inject(self: *Sram, bank: usize, slot: Slot) void {
        if (bank >= bank_count) return;
        self.esr |= bit(bank, slot);
        self.setFaultAddress(bank, slot);
        self.latches +%= 1;
    }

    pub fn read(self: *Sram, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        if (offset >= win_span) return 0;
        const word = offset / 4;
        const inner = offset % 4;
        if (word == off_esr / 4) return part(self.esr, inner, width);
        return part(self.shadow[word], inner, width);
    }

    pub fn write(self: *Sram, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        if (offset >= win_span) return;
        const word = offset / 4;
        const inner = offset % 4;
        if (word == off_esclr / 4) {
            self.clear(@truncate(merge(0, inner, width, value)));
            return;
        }
        if (word == off_esr / 4) {
            self.refuse(@truncate(merge(self.esr, inner, width, value)));
            return;
        }
        // The key is read from the value the register will hold, so a byte
        // store that completes a half-word key still opens the lock.
        const merged = merge(self.shadow[word], inner, width, value);
        if (self.lock.admit(offset - inner) == .blocked) return;
        self.shadow[word] = merged;
        _ = self.lock.latch(offset - inner, merged);
        if (word >= off_cr0 / 4 and word < off_cr0 / 4 + bank_count) {
            self.stepPhase(word - off_cr0 / 4, @truncate(self.shadow[word]));
        }
    }

    /// A store to SRAMESR. Clearing goes through SRAMESCLR, so the only thing
    /// a store here could do is raise a flag, and raising is the decoder's.
    fn refuse(self: *Sram, wanted: u16) void {
        self.faked +%= @popCount(wanted & ~self.esr);
    }

    /// Walk the bank through write -> bypass -> verify. Any other value drops
    /// it back to idle, so a half-run sequence does not latch later.
    fn stepPhase(self: *Sram, bank: usize, cr: u8) void {
        const at = &self.walk[bank];
        at.* = switch (cr) {
            phase.write => .wrote,
            phase.bypass => if (at.* == .wrote) .bypassed else .idle,
            phase.verify => blk: {
                if (at.* == .bypassed) self.latchBank(bank);
                break :blk .idle;
            },
            else => .idle,
        };
    }

    /// The verify read found the corrupted syndrome. Both slots go up: the
    /// model cannot see the data write, so it cannot tell one bit from two.
    fn latchBank(self: *Sram, bank: usize) void {
        self.esr |= bit(bank, .corrected) | bit(bank, .uncorrectable);
        self.setFaultAddress(bank, .corrected);
        self.setFaultAddress(bank, .uncorrectable);
        self.latches +%= 1;
    }

    fn setFaultAddress(self: *Sram, bank: usize, slot: Slot) void {
        self.shadow[earWord(bank, slot)] = bank_data_offset[bank];
    }

    /// SRAMESCLR: every slot the mask names loses its flag and its address.
    fn clear(self: *Sram, mask: u16) void {
        self.esr &= ~mask;
        for (0..bank_count) |bank| {
            for ([_]Slot{ .corrected, .uncorrectable }) |slot| {
                if (mask & bit(bank, slot) == 0) continue;
                self.shadow[earWord(bank, slot)] = 0;
            }
        }
    }

    pub fn block(self: *Sram) periph.Block {
        return .{
            .name = "SRAM-ECC",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

/// The SRAMESR bit for one bank's slot: two bits per bank, low bank first.
pub fn bit(bank: usize, slot: Slot) u16 {
    const position = @as(u32, @intCast(bank)) * @as(u32, slots_per_bank) + slot.index();
    return @as(u16, 1) << @intCast(position);
}

/// The address of one bank's SRAMCRn, so a test or a later slice does not do
/// the arithmetic itself.
pub fn crAddress(bank: usize) u32 {
    return win_base + off_cr0 + @as(u32, @intCast(bank)) * cr_stride;
}

/// The address of SRAMEAR[bank][slot].
pub fn earAddress(bank: usize, slot: Slot) u32 {
    return win_base + off_ear0 + @as(u32, @intCast(bank)) * ear_bank_stride +
        slot.index() * ear_slot_stride;
}

fn earWord(bank: usize, slot: Slot) usize {
    return (earAddress(bank, slot) - win_base) / 4;
}

/// The part of a 32-bit register a narrow access names.
fn part(value: anytype, byte_offset: u32, width: u3) u32 {
    const wide: u32 = value;
    if (width >= 4) return wide;
    const shift: u5 = @intCast(byte_offset * 8);
    const shifted = wide >> shift;
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
    const self: *Sram = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Sram = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
