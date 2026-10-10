//! DOC: the Data Operation Circuit, so a hardware sum equals its own reference.
//!
//! The RA8D2 DOC lives at 0x4031_1000 (HUM Ch 57.2, ra8_doc_regs.h) and is one
//! accumulator with a comparator bolted to it. Until now it fell through to the
//! sparse register file, and a sparse cell cannot accumulate: `doc_demo` in the
//! C tree chains an eight-entry add through the unit and compares the hardware
//! sum against a portable software sum, so DODSR0 reading back a stand-in
//! latched LED2 every run. The `RA8_OFF_TARGET` shortcut in ra8_doc.c that
//! computes the result in software is compiled out of the cross-target image
//! the emulator actually runs, so the genuine "write DODIR, read DODSR0" path
//! has to work. Ported from board_periph_doc.c on dev.
//!
//!   DOCR   (+0x00, 8b)  OMS[1:0] mode, DOBW width, DCSEL[2:0] compare relation
//!   DOSR   (+0x04, 8b)  DOPCF, the latched carry / borrow / comparison flag
//!   DOSCR  (+0x08, 8b)  write DOPCFCL to clear the flag
//!   DODIR  (+0x0C)      write-only operand in: each write runs one operation
//!   DODSR0 (+0x10)      reference in, running result out, seedable
//!   DODSR1 (+0x14)      upper threshold, read by the two window relations
//!
//! One DODIR write is one operation, and DOCR.OMS picks which:
//!   add      DODSR0 += DODIR, masked to the DOBW width, DOPCF on carry out
//!   subtract DODSR0 -= DODIR, masked, DOPCF on borrow
//!   compare  DODSR0 is left alone, DOPCF latches when the relation holds,
//!            and which relation that is comes from DOCR.DCSEL: see
//!            compare.zig, which owns the six encodings and reads DODSR1
//!            as the upper bound for the two window ones.
//!
//! DOPCF latches: once set it stays set until DOSCR clears it, which is what
//! lets a driver run a whole block through the unit and check overflow once at
//! the end rather than after every operand.
//!
//! DODIR IS A DATA PORT, NOT A BAG OF ADDRESSABLE LANES. The store prong here
//! tested the offset for equality with DODIR's own address, so the window
//! behaved two different wrong ways at once. A BYTE store at +0x0C ran a whole
//! operation with the byte sitting at lane 0 as the entire operand, which in
//! 32-bit mode folds a result into DODSR0 out of an operand whose top three
//! bytes the firmware never wrote. And a store landing ANYWHERE ABOVE lane 0,
//! the halfword at +0x0E a driver taking a 32-bit operand over a 16-bit bus
//! writes second, matched nothing and fell off the end of the function: the
//! operand half vanished, no operation ran, and the run said nothing about
//! either. Here an access must start at lane 0 and be at least as wide as the
//! operand DOCR.DOBW selects; anything narrower carries no operation, is
//! refused and counted, and DODSR0 keeps what it had. The rule and what it
//! deliberately does not claim about silicon live in
//! src/chip/periph/doc/operand.zig.
const std = @import("std");
const periph = @import("../registry.zig");
const doc_compare = @import("compare.zig");
const dodir = @import("operand.zig");

/// The detection condition DOCR.DCSEL selects, in its own file.
pub const compare = doc_compare;

/// The rule deciding whether a store to DODIR carries a whole operand.
pub const input = dodir;

/// DOC geometry (HUM Ch 57.2). The Non-secure alias is folded onto this base
/// by the bus before anything here sees it.
pub const win_base: u32 = 0x4031_1000;
pub const win_span: u32 = 0x20;

pub const off_docr: u32 = 0x00;
pub const off_dosr: u32 = 0x04;
pub const off_doscr: u32 = 0x08;
pub const off_dodir: u32 = 0x0C;
pub const off_dodsr0: u32 = 0x10;
pub const off_dodsr1: u32 = 0x14;

const oms_mask: u8 = 0x03;
pub const dobw_32: u8 = 0x08;
pub const dopcf: u8 = 0x01;

/// DOCR.OMS: what a DODIR write does.
pub const Mode = enum(u8) {
    compare = 0,
    add = 1,
    subtract = 2,
    _,
};

/// The unit: two operand registers, a mode byte and a sticky flag.
pub const Doc = struct {
    docr: u8 = 0,
    flag: bool = false,
    dodsr0: u32 = 0,
    dodsr1: u32 = 0,
    ops: u32 = 0,
    /// Compares run under one of the two DODSR1 window relations.
    windows: u32 = 0,
    /// Stores to DODIR too narrow, or too high up, to carry an operand.
    narrow_writes: u32 = 0,

    pub fn init() Doc {
        return .{};
    }

    pub fn mode(self: *const Doc) Mode {
        return @fromBackingInt(@intCast(self.docr & oms_mask));
    }

    /// DOCR.DOBW picks the arithmetic width: clear is 16-bit, set is 32-bit.
    pub fn wideOperand(self: *const Doc) bool {
        return self.docr & dobw_32 != 0;
    }

    pub fn widthMask(self: *const Doc) u32 {
        return if (self.wideOperand()) 0xFFFF_FFFF else 0x0000_FFFF;
    }

    /// The detection condition a compare currently answers.
    pub fn relation(self: *const Doc) compare.Relation {
        return compare.Relation.of(self.docr);
    }

    /// Untouched units stay out of the end-of-run report.
    pub fn quiet(self: *const Doc) bool {
        return self.ops == 0 and self.narrow_writes == 0;
    }

    /// Stores to DODIR that could not carry an operand.
    pub fn refused(self: *const Doc) u32 {
        return self.narrow_writes;
    }

    /// A store to DODIR. One store is one operation and the operand moves
    /// whole, so an access that names only part of the register runs nothing:
    /// there is one input latch behind this address, not four lanes half an
    /// operand could wait in.
    fn store(self: *Doc, lane: u32, width: u3, value: u32) void {
        if (!dodir.carriedBy(lane, width, self.wideOperand())) {
            self.narrow_writes +%= 1;
            return;
        }
        self.apply(value);
    }

    /// Run one operation with `operand` as the DODIR value.
    pub fn apply(self: *Doc, operand: u32) void {
        const mask = self.widthMask();
        const in = operand & mask;
        const current = self.dodsr0 & mask;
        switch (self.mode()) {
            .add => {
                // Widened on purpose: a 32-bit add that carries out of bit 31
                // wraps in a u32, and the C tree's `sum & ~mask` test can
                // therefore never fire in 32-bit mode. Silicon latches DOPCF
                // whenever the sum leaves the selected width, so the sum is
                // computed a width up and the carry read off the top.
                const sum = @as(u64, current) + @as(u64, in);
                if (sum & ~@as(u64, mask) != 0) self.flag = true;
                self.dodsr0 = @truncate(sum & mask);
            },
            .subtract => {
                if (in > current) self.flag = true;
                self.dodsr0 = (current -% in) & mask;
            },
            else => {
                // Compare leaves the accumulator alone; only the flag moves.
                // Which question is being asked is DOCR.DCSEL's to answer, and
                // the two window relations weigh the operand against DODSR1 as
                // well as DODSR0.
                const condition = compare.Relation.of(self.docr);
                if (condition.windowed()) self.windows +%= 1;
                if (compare.hit(condition, in, current, self.dodsr1 & mask)) self.flag = true;
            },
        }
        self.ops +%= 1;
    }

    pub fn read(self: *Doc, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        if (offset == off_docr) return self.docr;
        if (offset == off_dosr) return if (self.flag) dopcf else 0;
        if (offset >= off_dodsr0 and offset < off_dodsr0 + 4) {
            const shift: u5 = @intCast((offset - off_dodsr0) * 8);
            return trim(self.dodsr0 >> shift, width);
        }
        if (offset >= off_dodsr1 and offset < off_dodsr1 + 4) {
            const shift: u5 = @intCast((offset - off_dodsr1) * 8);
            return trim(self.dodsr1 >> shift, width);
        }
        // DODIR is write-only and DOSCR is a clear strobe: both read zero on
        // silicon, and zero beats the sparse file's alternating stand-in. A
        // driver polling here is reading a register with no value to give.
        return 0;
    }

    pub fn write(self: *Doc, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        if (offset == off_docr) {
            self.docr = @truncate(value);
            return;
        }
        if (offset == off_doscr) {
            if (@as(u8, @truncate(value)) & dopcf != 0) self.flag = false;
            return;
        }
        if (offset >= off_dodir and offset < off_dodir + 4) {
            self.store(offset - off_dodir, width, value);
            return;
        }
        if (offset >= off_dodsr0 and offset < off_dodsr0 + 4) {
            self.dodsr0 = merge(self.dodsr0, offset - off_dodsr0, width, value);
            return;
        }
        if (offset >= off_dodsr1 and offset < off_dodsr1 + 4) {
            self.dodsr1 = merge(self.dodsr1, offset - off_dodsr1, width, value);
            return;
        }
        // DOSR.DOPCF is read-only: it is cleared through DOSCR, never by
        // writing the status register.
    }

    pub fn block(self: *Doc) periph.Block {
        return .{
            .name = "DOC",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn trim(value: u32, width: u3) u32 {
    return switch (width) {
        1 => value & 0xFF,
        2 => value & 0xFFFF,
        else => value,
    };
}

/// Fold a narrow write into a 32-bit register without disturbing the bytes the
/// access does not name.
fn merge(current: u32, byte_offset: u32, width: u3, value: u32) u32 {
    if (width >= 4 and byte_offset == 0) return value;
    const shift: u5 = @intCast(byte_offset * 8);
    const window = trim(0xFFFF_FFFF, width) << shift;
    return (current & ~window) | ((value << shift) & window);
}

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Doc = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Doc = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}

/// The address of one DOC register, so a test or a later slice does not have
/// to do the arithmetic itself.
pub fn regAddress(offset: u32) u32 {
    return win_base + offset;
}

pub const reg_docr = off_docr;
pub const reg_dosr = off_dosr;
pub const reg_doscr = off_doscr;
pub const reg_dodir = off_dodir;
pub const reg_dodsr0 = off_dodsr0;
pub const reg_dodsr1 = off_dodsr1;
