//! XSPI0: the manual-command engine in front of the octal NOR flash, and the
//! write-enable latch that decides whether a command is allowed to change
//! the part.
//!
//! The window sits at 0x4026_8000 (ra8_ospi_regs.h). The driver's sequence
//! is the same one the real part wants: fill the slot-0 command descriptor
//! in CDBUF (CDT, address, then two data words), set CDCTL0.TRREQ, poll
//! INTS.CMDCMP, clear it through INTC, and read the data words back. This
//! model decodes the descriptor, runs the opcode against the NOR array in
//! the part (nor.zig), raises CMDCMP and drops TRREQ.
//!
//! Ported from board_periph_xspi.c on dev, with four things that model does
//! not do.
//!
//! WRITE ENABLE IS A LATCH, NOT A DECORATION. dev answers RDSR with WEL
//! permanently set and programs or erases whatever the descriptor asks,
//! WREN or no WREN. A driver that forgets the write-enable therefore works
//! here and fails on silicon, which is the worst direction for a model to be
//! wrong in. Here WREN sets the latch, a program or erase without it is
//! refused and counted, a completed program or erase clears it again, and
//! RDSR reports the latch the model is actually holding.
//!
//! A DESCRIPTOR CANNOT ASK FOR MORE THAN THE SLOT HOLDS. DATASIZE is four
//! bits, so it can name up to fifteen bytes, and slot 0 has two data words:
//! eight. dev shifts the ninth byte by thirty-two inside a 32-bit word,
//! which is undefined in C and in practice quietly folds back onto the
//! first. Here a descriptor past eight bytes is refused and counted, and so
//! is one whose address and length run off the end of the part rather than
//! being skipped a byte at a time.
//!
//! INTS IS WHAT THE ENGINE RAISED. dev drops any store into the window
//! shadow, INTS included, so an image can write CMDCMP itself and read back
//! a command that completed without a command ever running. Here a store to
//! INTS is refused and counted, the way this tree already treats CETCR and
//! SRAMESR, and INTC stays the only way the flag goes down.
//!
//! NARROW WRITES KEEP THE BYTES THEY DO NOT NAME. dev assigns the whole
//! value into regs[off / 4], so a byte store to CDCTL0 wipes CSSEL above it
//! and the transfer goes to the wrong chip select.
//!
//! A PAGE PROGRAM STAYS IN ITS PAGE. dev walks the address straight up from
//! the one the descriptor names, so a program that starts near the end of a
//! 256-byte page spills its tail into the NEXT page. The part does not do
//! that: the program counter is page-wide, so the tail wraps to the start of
//! the page it began in and overwrites what the same command just wrote. A
//! driver that gets this wrong sees the right bytes here and the wrong ones
//! on silicon, in the direction a model must never be wrong in. Here the
//! program wraps, and a command that wrapped is counted so the run says so.
//! A READ IS NOT PAGED and still streams straight on across pages and
//! sectors, which is why only the program path carries the arithmetic.
//! It follows that a page program cannot run off the end of the part at all:
//! only a start address already past the end is out of the part, which is
//! the same test the erase path uses.
//!
//! NOT MODELLED, AND NOT GUESSED: the memory-mapped read path (CSa space),
//! WRAPCFG and the timing and calibration registers, the second command
//! slot, INTE's masks, and every status bit besides CMDCMP. No header for
//! this part is in this tree to give them. The rest of the window is
//! shadowed so a read-modify-write survives, and never interpreted. WIP
//! reads clear because a command completes inside the store that kicked it:
//! there is no time in this model for the part to still be busy.
const std = @import("std");
const octaclk = @import("../octaclk.zig");
const periph = @import("../registry.zig");
const xspi_nor = @import("nor.zig");
pub const reset = @import("reset.zig");
const lanes = @import("../lanes.zig");

/// XSPI0 geometry.
pub const win_base: u32 = 0x4026_8000;
pub const win_span: u32 = 0x200;

/// The registers this model interprets. Everything else in the window is
/// shadow.
pub const off_cdctl0: u32 = 0x070;
pub const off_cdbuf: u32 = 0x080;
pub const off_ints: u32 = 0x190;
pub const off_intc: u32 = 0x194;

/// The bits dev's own masks name.
pub const field = struct {
    /// CDCTL0.TRREQ, the kick. It self-clears when the command completes.
    pub const trreq: u32 = 0x0000_0001;
    /// INTS.CMDCMP, command complete.
    pub const cmdcmp: u32 = 0x0000_0001;
};

/// The slot-0 command descriptor: four words at CDBUF.
pub const slot = struct {
    pub const cdt: u32 = 0;
    pub const address: u32 = 1;
    pub const data0: u32 = 2;
    pub const data1: u32 = 3;
    /// Bytes the two data words hold, and so the most one command can move.
    pub const data_bytes: u32 = 8;
};

/// CDT field positions and widths (ra8_ospi_regs.h).
pub const descriptor = struct {
    pub const pos_cmdsize: u5 = 0;
    pub const mask_cmdsize: u32 = 0x3;
    pub const pos_datasize: u5 = 5;
    pub const mask_datasize: u32 = 0xF;
    pub const pos_cmd: u5 = 16;
    pub const mask_cmd: u32 = 0xFFFF;

    /// The opcode byte, recovered from the left-justified CMD field: the
    /// driver puts a one-byte opcode in the high half of CMD and a two-byte
    /// one across both.
    pub fn opcode(cdt: u32) u8 {
        const size = (cdt >> pos_cmdsize) & mask_cmdsize;
        const command = (cdt >> pos_cmd) & mask_cmd;
        const shift: u5 = @intCast(8 * (2 -| size));
        return @truncate(command >> shift);
    }

    pub fn dataSize(cdt: u32) u32 {
        return (cdt >> pos_datasize) & mask_datasize;
    }
};

/// The JEDEC opcodes the engine decodes. The software reset pair is
/// sequenced in reset.zig; everything else (mode switches) completes
/// without touching the part, as it does on dev.
pub const Opcode = enum(u8) {
    page_program = 0x02,
    read = 0x03,
    read_status = 0x05,
    write_enable = 0x06,
    sector_erase = 0x20,
    read_id = 0x9F,
    _,
};

/// RDSR result bits.
pub const status = struct {
    /// Write in progress. Never set here: a command completes inside the
    /// store that kicked it.
    pub const wip: u32 = 0x01;
    /// Write enable latch.
    pub const wel: u32 = 0x02;
};

const shadow_words: usize = win_span / 4;

pub const Xspi = struct {
    /// The NOR part, plugged in by the board. With none, every command that
    /// reaches for the part runs off it.
    part: ?xspi_nor.Nor = null,
    /// The OCTACLK watch, or null on a board without one, in which case the
    /// engine works the way it always did here.
    octa: ?*const octaclk.Octa = null,
    shadow: [shadow_words]u32 = @splat(0),
    /// INTS.CMDCMP, held rather than shadowed.
    complete: bool = false,
    /// The write-enable latch WREN sets and a program or erase spends.
    write_enabled: bool = false,
    /// RSTEN then RST, which drops the latch.
    resetting: reset.Sequence = .{},
    reads: u32 = 0,
    programs: u32 = 0,
    erases: u32 = 0,
    /// Programs and erases that arrived with the latch clear.
    unarmed: u32 = 0,
    /// Descriptors asking for more bytes than slot 0 holds.
    oversized: u32 = 0,
    /// Commands whose address and length run off the end of the part.
    out_of_part: u32 = 0,
    /// Programs whose tail wrapped to the start of its own page.
    wrapped: u32 = 0,
    /// Stores to INTS: firmware cannot raise a completion itself.
    faked: u32 = 0,
    /// Programs the model could not find room to hold.
    lost: u32 = 0,
    /// Kicks that went nowhere because the OSPI came out of module stop
    /// before OCTACLK was declared stable.
    stalled: u32 = 0,

    pub fn quiet(self: *const Xspi) bool {
        return self.reads == 0 and self.programs == 0 and self.erases == 0 and
            self.unarmed == 0 and self.oversized == 0 and self.out_of_part == 0 and
            self.wrapped == 0 and self.faked == 0 and self.lost == 0 and
            self.stalled == 0;
    }

    pub fn read(self: *Xspi, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        if (offset >= win_span) return 0;
        const byte = offset % 4;
        return switch (offset & ~@as(u32, 3)) {
            off_ints => lanes.part(self.interrupts(), byte, width),
            // Write-one-to-clear, with nothing behind it to read.
            off_intc => 0,
            else => lanes.part(self.shadow[offset / 4], byte, width),
        };
    }

    pub fn write(self: *Xspi, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        if (offset >= win_span) return;
        const byte = offset % 4;
        switch (offset & ~@as(u32, 3)) {
            off_ints => self.faked +%= 1,
            off_intc => {
                if (lanes.merge(0, byte, width, value) & field.cmdcmp != 0) self.complete = false;
            },
            off_cdctl0 => {
                const word = self.store(offset, byte, width, value);
                if (word & field.trreq == 0) return;
                if (self.stalledByClock()) return;
                self.execute();
                self.shadow[offset / 4] &= ~field.trreq;
            },
            else => _ = self.store(offset, byte, width, value),
        }
    }

    /// HUM Ch 11.2.7 MSTPCRB Note 3: the OSPI module-stop bits must be
    /// written after OCTACLK is stable. Released early, the manual-command
    /// engine cannot retire CDCTL0.TRREQ after the first CDT write, so the
    /// kick lands, TRREQ stays up, CMDCMP never comes, and the driver's
    /// bounded poll gives up with a hardware timeout. That is the bench
    /// symptom ra8_xspi.c records, and it is what this returns true for.
    fn stalledByClock(self: *Xspi) bool {
        const unit = self.octa orelse return false;
        if (!unit.wedged) return false;
        self.stalled +%= 1;
        return true;
    }

    /// INTS as this model computes it.
    fn interrupts(self: *const Xspi) u32 {
        return if (self.complete) field.cmdcmp else 0;
    }

    fn store(self: *Xspi, offset: u32, byte: u32, width: u3, value: u32) u32 {
        const word = offset / 4;
        self.shadow[word] = lanes.merge(self.shadow[word], byte, width, value);
        return self.shadow[word];
    }

    fn buffer(self: *Xspi, index: u32) *u32 {
        return &self.shadow[(off_cdbuf / 4) + index];
    }

    /// Run the slot-0 command and raise CMDCMP. A refused command still
    /// completes: the engine has done with the descriptor either way, and a
    /// driver polling CMDCMP would otherwise hang on a mistake the report
    /// already names.
    fn execute(self: *Xspi) void {
        const cdt = self.buffer(slot.cdt).*;
        const address = self.buffer(slot.address).*;
        const size = descriptor.dataSize(cdt);
        if (self.resetting.step(descriptor.opcode(cdt))) self.write_enabled = false;
        switch (@as(Opcode, @fromBackingInt(@intCast(descriptor.opcode(cdt))))) {
            .read_id => self.buffer(slot.data0).* = if (self.part) |nor| nor.jedecWord() else 0,
            .read_status => self.buffer(slot.data0).* = if (self.write_enabled) status.wel else 0,
            .write_enable => self.write_enabled = true,
            .read => self.doRead(address, size),
            .page_program => self.doProgram(address, size),
            .sector_erase => self.doErase(address),
            else => {},
        }
        self.complete = true;
    }

    /// Copy the data bytes out of the part into CDD0 and CDD1.
    fn doRead(self: *Xspi, address: u32, size: u32) void {
        if (!self.fits(address, size)) return;
        var words = [2]u32{ 0, 0 };
        for (0..size) |index| {
            const value: u32 = self.part.?.byte(address + @as(u32, @intCast(index)));
            const shift: u5 = @intCast((index % 4) * 8);
            words[index / 4] |= value << shift;
        }
        self.buffer(slot.data0).* = words[0];
        self.buffer(slot.data1).* = words[1];
        self.reads +%= 1;
    }

    /// Program the data bytes into the part. NOR only clears bits, so this
    /// cannot put a one back where a previous program took it away, and the
    /// address counter is only as wide as a page, so a tail past the end of
    /// the page lands back at the start of the same page.
    fn doProgram(self: *Xspi, address: u32, size: u32) void {
        if (!self.armed()) return;
        if (!self.fitsProgram(address, size)) return;
        if (self.part.?.crossesPage(address, size)) self.wrapped +%= 1;
        const words = [2]u32{ self.buffer(slot.data0).*, self.buffer(slot.data1).* };
        for (0..size) |index| {
            const shift: u5 = @intCast((index % 4) * 8);
            const value: u8 = @truncate(words[index / 4] >> shift);
            const at = self.part.?.programStep(address, @intCast(index));
            if (!self.part.?.program(at, value)) {
                self.lost +%= 1;
                return;
            }
        }
        self.programs +%= 1;
        self.write_enabled = false;
    }

    /// Erase the 4 KiB sector the address falls in.
    fn doErase(self: *Xspi, address: u32) void {
        if (!self.armed()) return;
        const nor = self.part orelse {
            self.out_of_part +%= 1;
            return;
        };
        if (address >= nor.capacity()) {
            self.out_of_part +%= 1;
            return;
        }
        nor.erase(address);
        self.erases +%= 1;
        self.write_enabled = false;
    }

    /// The write-enable latch, checked the way the part checks it.
    fn armed(self: *Xspi) bool {
        if (self.write_enabled) return true;
        self.unarmed +%= 1;
        return false;
    }

    /// Whether slot 0 and the part can both carry a program. A program stays
    /// inside the page it started in, so the only way off the part is a start
    /// address that is already past the end of it.
    fn fitsProgram(self: *Xspi, address: u32, size: u32) bool {
        if (size > slot.data_bytes) {
            self.oversized +%= 1;
            return false;
        }
        const nor = self.part orelse {
            self.out_of_part +%= 1;
            return false;
        };
        if (address >= nor.capacity()) {
            self.out_of_part +%= 1;
            return false;
        }
        return true;
    }

    /// Whether slot 0 and the part can both carry a read, which is not paged
    /// and so really can run off the end.
    fn fits(self: *Xspi, address: u32, size: u32) bool {
        if (size > slot.data_bytes) {
            self.oversized +%= 1;
            return false;
        }
        const nor = self.part orelse {
            self.out_of_part +%= 1;
            return false;
        };
        if (!nor.holds(address, size)) {
            self.out_of_part +%= 1;
            return false;
        }
        return true;
    }

    pub fn block(self: *Xspi) periph.Block {
        return .{
            .name = "XSPI",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Xspi = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Xspi = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}

/// The address of a slot-0 command-descriptor word, so a test or a later
/// slice does not do the arithmetic itself.
pub fn bufferAddress(index: u32) u32 {
    return win_base + off_cdbuf + index * 4;
}
