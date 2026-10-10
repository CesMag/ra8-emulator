//! The extra-MRAM controller: program/erase mode, the command the sequencer
//! collected, and whether the option-setting memory is allowed to take it.
//!
//! Three windows share one model, the way one block of silicon does. The
//! MRMS program-mode registers sit at 0x4013_E000 (MSADDR, MSTATR, MENTRYR,
//! MASTAT), the MACI command-issuing port at 0x4012_0000, and the code-MRAM
//! program-control page at 0x4013_F000. The driver's sequence is MENTRYR =
//! 0xAA80 to enter program/erase mode, MSADDR = the target, the command
//! stream through the port, a poll of MSTATR for MRDY and the error mask,
//! then MENTRYR = 0xAA00 on the way out.
//!
//! Ported from board_periph_mram.c on dev, with five things that model does
//! not do.
//!
//! MSTATR IS WHAT THE SEQUENCER LEFT. dev answers every MSTATR read with
//! MRDY and nothing else, including straight after its own reject path has
//! latched ILGCOMERR and ILGLERR into the shadow. So a driver that issues an
//! illegal Program, polls MRDY and checks the error mask, which is exactly
//! the sequence dev's own header documents, reads a clean completion. Here
//! MSTATR reports the latched errors beside MRDY.
//!
//! COMMAND-LOCKED ACTUALLY LOCKS. HUM Ch 59.7.4.4 p 3590: once the
//! sequencer is command-locked, MACI commands cannot be accepted. dev
//! latches CMDLK and then runs the next command anyway. Here a command
//! arriving locked is refused and counted, and the lock is released by
//! leaving program/erase mode. That release is this model's own rule, not a
//! ported one: no opcode for Status Clear or Forced Stop is in this tree to
//! take, and a lock with no way out would hang an image rather than tell it
//! anything.
//!
//! A COMMAND NEEDS PROGRAM/ERASE MODE, AND MENTRYR NEEDS ITS KEY. dev runs
//! the command stream whether or not MENTRYR was ever written, and takes any
//! value with bit 7 set as an entry, key or no key. Both are refused and
//! counted here; the key is the 0xAA the two writes dev's own header
//! documents both carry.
//!
//! A PAUSE IS A STATE, NOT A WRITE THAT VANISHES. MENTRYR.PCKA is the gate
//! ra8_flash_suspend and ra8_flash_resume drive: suspend stores the keyed
//! pause pattern 0xAAC0 and polls for PCKA standing, resume stores 0xAA80
//! and polls for it gone. Neither dev nor this model carried the bit at
//! all, and MENTRYR reads back the mode bit alone, so every suspend spun
//! its whole 0x10000-iteration budget and returned a hw timeout, while
//! every resume answered instantly whether or not anything was paused.
//! PCKA now follows the keyed write and reads back beside MENTRY, and
//! leaving program/erase mode drops it the way it drops the lock.
//!
//! STATUS IS CONTROLLER-OWNED. dev stores any value written anywhere in the
//! window into its shadow, MSTATR and MASTAT included, so firmware can clear
//! the error bits its own illegal command raised. Refused and counted here,
//! the way this tree already treats CETCR, SRAMESR and INTS. Narrow writes
//! keep the bytes they do not name, where dev's regs[off / 4] = value wipes
//! them.
//!
//! THE KEY HAS TO BE IN THE WRITE. MENTRYR is a sixteen-bit register whose
//! high half is the key and whose bit 7 is the mode, and the driver writes
//! the pair in one halfword store, 0xAA80 in and 0xAA00 out. The key was
//! judged on the word AFTER the store had been folded into the shadow, so
//! the 0xAA of an earlier keyed write stayed there and vouched for every
//! later access: a byte store of 0x80 at MENTRYR, which names no part of
//! the key at all, read as 0xAA80 and entered program/erase mode. Now an
//! access has to name the whole register, and the key is read out of the
//! value the access itself carries, never out of what was already stored.
//! A store that names less than the register carries no key, so it is
//! refused and counted and the mode does not move. This is the SSIFTDR and
//! TXD cut applied to a protection key rather than to a data port. MENTRYR
//! is sixteen bits, so an access landing entirely in the two bytes above it
//! names no part of the register and still merges into the shadow the way
//! it always did.
//!
//! MSUINITR IS A KICK, AND THE SEQUENCER TAKES SUINIT BACK DOWN. It fell
//! into the generic shadow below, so a store landed 0xAA01 in a word and a
//! read handed it straight back: SUINIT was still standing on every poll
//! and ra8_flash_msuinitr_kick always ran out its spin limit and returned
//! a hardware timeout. The rule and its evidence are in init.zig.
//!
//! NOT MODELLED, AND NOT GUESSED: the 0x4013_C000 wait-state and ECC
//! configuration pages, which stay sparse because ra8_cgc_init programs them
//! during clock setup with a key-strip readback this model would have to
//! invent; the erase and blank-check commands; and every MSTATR bit besides
//! MRDY and the two illegal-command latches. The code-MRAM page is its own
//! file, code.zig: MRCPS still reads idle-and-ready the way dev leaves
//! it, and a store to it is refused there for the same reason a store to
//! MSTATR is refused here.
const std = @import("std");
const Guest = @import("../../core/cpu/memory/guest.zig").Guest;
const periph = @import("../registry.zig");
const lanes = @import("../lanes.zig");
const maci = @import("../maci.zig");
const cells = @import("otp.zig");
const code = @import("code.zig");
const mram_regs = @import("regs.zig");

pub const window = cells.window;

/// The option window mapped as readable memory: window.zig.
pub const option_window = @import("window.zig");

/// Where these registers sit and what their bits mean: regs.zig.
pub const regs = mram_regs.regs;
pub const command = mram_regs.command;
pub const field = mram_regs.field;

/// The code-MRAM program-control page (the R_MRMS 0x3000 page), which
/// answers for itself in code.zig.
pub const code_page = code.page;

/// MSUINITR, the set-up init kick, and its rule: init.zig.
pub const init_reg = @import("init.zig");

/// MENTRYR, the mode gate and its key: entry.zig.
pub const entry_reg = @import("entry.zig");

const shadow_words: usize = regs.span / 4;

pub const Mram = struct {
    otp: cells.Cells,
    stream: maci.Sequencer = .{},
    shadow: [shadow_words]u32 = @splat(0),
    /// The code-MRAM program-control page: a different program path on the
    /// same controller, so it shares this block and owns its own rules.
    code: code.Page = .{},
    /// MSUINITR's set-up init state.
    setup: init_reg.Init = .{},
    /// Where a program that lands is also written through, so firmware can
    /// read the option word back. A board built by a test leaves it null and
    /// the write-through is skipped; the cells still hold the program.
    memory: ?Guest = null,
    /// The latched MSTATR error bits, held rather than shadowed.
    errors: u32 = 0,
    /// The latched MASTAT access bits.
    access: u32 = 0,
    msaddr: u32 = 0,
    /// MENTRYR: the mode gate, its key, and the pause bit.
    entry: entry_reg.Entry = .{},
    locked: bool = false,

    programs: u32 = 0,
    config_sets: u32 = 0,
    /// Commands aimed outside HUM Table 59.15's window.
    illegal: u32 = 0,
    /// Commands that arrived while the sequencer was command-locked.
    locked_out: u32 = 0,
    /// Commands that arrived while PCKA held the sequencer paused.
    paused_kicks: u32 = 0,
    /// Commands that arrived without program/erase mode entered.
    outside_mode: u32 = 0,
    /// Trailers on a stream that never carried what it declared.
    malformed: u32 = 0,
    /// Programs asking a one-time-programmable cell for a bit back.
    rewrites: u32 = 0,
    /// Stores to MSTATR or MASTAT: firmware cannot clear its own errors.
    read_only: u32 = 0,
    /// Programs the guest memory behind the option window refused.
    faulted: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) Mram {
        return .{ .otp = cells.Cells.init(allocator) };
    }

    pub fn deinit(self: *Mram) void {
        self.otp.deinit();
    }

    pub fn quiet(self: *const Mram) bool {
        return self.programs == 0 and self.config_sets == 0 and self.illegal == 0 and
            self.locked_out == 0 and self.paused_kicks == 0 and
            self.outside_mode == 0 and self.malformed == 0 and
            self.rewrites == 0 and self.read_only == 0 and self.entry.quiet() and
            self.faulted == 0 and self.code.quiet() and self.setup.quiet();
    }

    /// MSTATR as this model computes it: ready, plus whatever the sequencer
    /// latched.
    pub fn status(self: *const Mram) u32 {
        return field.mrdy | self.errors;
    }

    pub fn read(self: *Mram, address: u32, width: u3) u32 {
        const offset = address -% regs.base;
        if (offset >= regs.span) return 0;
        const byte = offset % 4;
        return switch (offset & ~@as(u32, 3)) {
            regs.off_mentryr => lanes.part(self.entry.status(), byte, width),
            regs.off_mstatr => lanes.part(self.status(), byte, width),
            regs.off_mastat => lanes.part(self.access, byte, width),
            init_reg.off => lanes.part(self.setup.read(), byte, width),
            else => lanes.part(self.shadow[offset / 4], byte, width),
        };
    }

    pub fn write(self: *Mram, address: u32, width: u3, value: u32) void {
        const offset = address -% regs.base;
        if (offset >= regs.span) return;
        const byte = offset % 4;
        switch (offset & ~@as(u32, 3)) {
            regs.off_mstatr, regs.off_mastat => self.read_only +%= 1,
            regs.off_mentryr => self.enter(offset, byte, width, value),
            regs.off_msaddr => self.msaddr = self.store(offset, byte, width, value),
            init_reg.off => self.setup.write(byte, width, value),
            else => _ = self.store(offset, byte, width, value),
        }
    }

    /// The MACI port. A halfword is payload; a byte is a command step.
    pub fn commandWrite(self: *Mram, width: u3, value: u32) void {
        if (width == 2) {
            self.stream.halfwordWritten(@truncate(value));
            return;
        }
        if (self.stream.byteWritten(@truncate(value)) != .commit) return;
        self.run();
        self.stream.reset();
    }

    pub fn codeRead(self: *Mram, address: u32, width: u3) u32 {
        return self.code.read(address, width);
    }

    pub fn codeWrite(self: *Mram, address: u32, width: u3, value: u32) void {
        self.code.write(address, width, value);
    }

    /// MENTRYR. The key has to be carried by the access itself, and leaving
    /// program/erase mode is what releases a command-locked sequencer.
    fn enter(self: *Mram, offset: u32, byte: u32, width: u3, value: u32) void {
        if (byte >= regs.mentryr_bytes) {
            _ = self.store(offset, byte, width, value);
            return;
        }
        const outcome = self.entry.write(byte, width, value);
        if (outcome == .refused) return;
        const word = offset / 4;
        self.shadow[word] = lanes.merge(self.shadow[word], byte, width, value);
        if (outcome == .entered) return;
        self.locked = false;
        self.errors = 0;
        self.access = 0;
    }

    /// Run the command the trailer just started.
    fn run(self: *Mram) void {
        if (self.locked) {
            self.locked_out +%= 1;
            return;
        }
        if (!self.entry.in_pe_mode) {
            self.outside_mode +%= 1;
            return;
        }
        if (self.entry.paused) {
            self.paused_kicks +%= 1;
            return;
        }
        if (!self.stream.complete()) {
            self.malformed +%= 1;
            return;
        }
        const payload = self.stream.bytes();
        if (!window.holds(self.msaddr, payload.len)) return self.reject();
        if (self.otp.rewrites(self.msaddr, payload)) {
            self.rewrites +%= 1;
            return;
        }
        self.commit(payload);
    }

    /// Program the payload into the cells, and through to guest memory so a
    /// read-back of the option word sees it.
    fn commit(self: *Mram, payload: []const u8) void {
        self.otp.program(self.msaddr, payload) catch {
            self.faulted +%= 1;
            return;
        };
        if (self.memory) |memory| {
            memory.write(self.msaddr, payload) catch {
                self.faulted +%= 1;
                return;
            };
        }
        switch (self.stream.kind) {
            .program => self.programs +%= 1,
            .config_set => self.config_sets +%= 1,
        }
    }

    /// The command-locked state a rejection leaves behind, in the bits a
    /// by-hand reproduction on an EK-RA8D2 reports: MSTATR 0x0080C000,
    /// MASTAT 0x18.
    fn reject(self: *Mram) void {
        self.errors |= field.ilgcomerr | field.ilglerr;
        self.access |= field.cmdlk | field.mreae;
        self.locked = true;
        self.illegal +%= 1;
    }

    fn store(self: *Mram, offset: u32, byte: u32, width: u3, value: u32) u32 {
        const word = offset / 4;
        self.shadow[word] = lanes.merge(self.shadow[word], byte, width, value);
        return self.shadow[word];
    }

    /// Put every window the option memory answers for on the bus, and hand
    /// it the machine a landed program is written through to.
    pub fn attach(self: *Mram, bus: *periph.Bus, machine: Guest) periph.Error!void {
        self.memory = machine;
        _ = option_window.map(machine) catch 0;
        try bus.add(self.block());
        try bus.add(self.commandBlock());
        try bus.add(self.codeBlock());
    }

    pub fn block(self: *Mram) periph.Block {
        return .{
            .name = "MRAM",
            .base = regs.base,
            .size = regs.span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }

    pub fn commandBlock(self: *Mram) periph.Block {
        return .{
            .name = "MACI",
            .base = command.base,
            .size = command.span,
            .context = self,
            .readFn = commandReadThunk,
            .writeFn = commandWriteThunk,
        };
    }

    pub fn codeBlock(self: *Mram) periph.Block {
        return .{
            .name = "MRAM-pgm",
            .base = code_page.base,
            .size = code_page.span,
            .context = self,
            .readFn = codeReadThunk,
            .writeFn = codeWriteThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Mram = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Mram = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}

/// The port answers zero: the result of a command is in MSTATR, not here.
fn commandReadThunk(context: *anyopaque, address: u32, width: u3) u32 {
    _ = context;
    _ = address;
    _ = width;
    return 0;
}

fn commandWriteThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    _ = address;
    const self: *Mram = @ptrCast(@alignCast(context));
    self.commandWrite(width, value);
}

fn codeReadThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Mram = @ptrCast(@alignCast(context));
    return self.codeRead(address, width);
}

fn codeWriteThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Mram = @ptrCast(@alignCast(context));
    self.codeWrite(address, width, value);
}
