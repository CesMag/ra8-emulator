//! Module Stop Control: the MSTPCRA..E window, and the gate it holds over the
//! rest of the peripheral bus.
//!
//! Every RA8D2 peripheral has a module-stop bit in one of MSTPCRA..MSTPCRE
//! (R_MSTP at 0x4020_3000, HUM Ch 11.2.6..11.2.10 p 443-450). While that bit
//! is set the peripheral is clock-gated off: it does not answer the bus, so
//! its registers read zero and writes vanish. Out of reset every peripheral
//! bit is 1, and firmware has to clear the bit before it may touch the block.
//!
//! Without this, a driver that forgot to cancel module-stop worked perfectly
//! in the emulator and did nothing on silicon, because the bus answered every
//! register whether or not the block was clocked. That is the masked pass this
//! file ends, and it is also what makes the mandated read-back after an
//! ungate settle: MSTPCRx is real state here, not a sparse cell that toggles.
//!
//! A module-stop bit follows its peripheral's security attribution. Once the
//! Secure side delegates a peripheral to the Non-secure world (R_PSCU, the
//! PSARB..PSARE words next door at 0x4020_4000), that MSTPCRx bit is owned by
//! the Non-secure alias and a Secure write to it is MASKED: the bit does not
//! change. `attribution` is that block, read live on every store rather than
//! copied, so a delegation made mid-run takes effect on the next write. A
//! board built without one delegates nothing and every bit stays writable,
//! which is also what the part does out of reset.
//!
//! The shadow and the address -> bit table are plain data and arithmetic, so
//! everything below is tested directly rather than only through a full run.
const std = @import("std");
const periph = @import("../registry.zig");
pub const drops = @import("drops.zig");
const octaclk = @import("../octaclk.zig");
const pscu = @import("../pscu.zig");

/// R_MSTP geometry (HUM Ch 11.2.6..11.2.10). The Non-secure alias at
/// 0x5020_3000 is folded onto this base by the bus before it ever gets here.
pub const win_base: u32 = 0x4020_3000;
pub const win_span: u32 = 0x14;

/// MSTPCRA..MSTPCRE.
pub const reg_count: u32 = 5;

/// Reset values (HUM Ch 11.2.6 p 443). MSTPCRA keeps SRAM0..3 (bits 0..3)
/// running because the stack lives there; everything else resets stopped.
pub const reset_a: u32 = 0xFFFF_FFF0;
pub const reset_rest: u32 = 0xFFFF_FFFF;

/// A module-stop id packed the way the firmware's own header packs it:
/// (register << 8) | bit.
fn id(register: u16, bit: u16) u16 {
    return (register << 8) | bit;
}

const reg_a: u16 = 0;
const reg_b: u16 = 1;
const reg_c: u16 = 2;
const reg_d: u16 = 3;
const reg_e: u16 = 4;

// MSTPCRB, HUM 11.2.7 p 444-445: SCI0..SCI9 are bits 31 down to 22.
const ids_sci = [_]u16{
    id(reg_b, 31), id(reg_b, 30), id(reg_b, 29), id(reg_b, 28), id(reg_b, 27),
    id(reg_b, 26), id(reg_b, 25), id(reg_b, 24), id(reg_b, 23), id(reg_b, 22),
};
const ids_spi = [_]u16{ id(reg_b, 19), id(reg_b, 18) };
const ids_riic = [_]u16{ id(reg_b, 9), id(reg_b, 8), id(reg_b, 7) };
const ids_i3c = [_]u16{id(reg_b, 4)};
const ids_xspi = [_]u16{id(reg_b, 16)};
// MSTPCRD, HUM 11.2.9 p 448-449.
const ids_agt = [_]u16{ id(reg_d, 5), id(reg_d, 4) };
const ids_dac = [_]u16{ id(reg_d, 20), id(reg_d, 19) };
const ids_poeg = [_]u16{ id(reg_d, 14), id(reg_d, 13), id(reg_d, 12), id(reg_d, 11) };
const ids_adc = [_]u16{id(reg_d, 21)};
// MSTPCRE, HUM 11.2.10 p 449-450. GPT4..GPT9 share one bit, MSTPE27.
const ids_gpt = [_]u16{
    id(reg_e, 31), id(reg_e, 30), id(reg_e, 29), id(reg_e, 28), id(reg_e, 27),
    id(reg_e, 27), id(reg_e, 27), id(reg_e, 27), id(reg_e, 27), id(reg_e, 27),
    id(reg_e, 21), id(reg_e, 20), id(reg_e, 19), id(reg_e, 18),
};
const ids_ulpt = [_]u16{ id(reg_e, 9), id(reg_e, 8) };
// MSTPCRC, HUM 11.2.8 p 446-447.
const ids_ssie = [_]u16{ id(reg_c, 8), id(reg_c, 7) };
const ids_canfd0 = [_]u16{id(reg_c, 27)};
const ids_canfd1 = [_]u16{id(reg_c, 26)};
const ids_cac = [_]u16{id(reg_c, 0)};
const ids_crc = [_]u16{id(reg_c, 1)};
const ids_doc = [_]u16{id(reg_c, 13)};
const ids_ceu = [_]u16{id(reg_c, 16)};
const ids_pdm = [_]u16{id(reg_c, 24)};
const ids_sdhi = [_]u16{id(reg_c, 12)};
const ids_drw = [_]u16{id(reg_c, 6)};

/// One strided run of instances that share a mapping shape: instance i lives
/// at base + stride * i and is governed by ids[i]. A single peripheral is a
/// family of one whose stride is its whole register window.
const Family = struct {
    base: u32,
    stride: u32,
    ids: []const u16,
    name: []const u8,

    pub fn span(self: Family) u64 {
        return @as(u64, self.stride) * self.ids.len;
    }
};

/// Every gated peripheral instance. A block with no module-stop control
/// (PORT, ICU, SYSC), a memory controller, an always-on block, and the shared
/// DMAC+DTC pair are deliberately absent: they are not gated on silicon, or
/// gating them would model a trap the firmware cannot fall into.
pub const families = [_]Family{
    .{ .base = 0x4035_8000, .stride = 0x100, .ids = &ids_sci, .name = "SCI" },
    .{ .base = 0x4035_C000, .stride = 0x100, .ids = &ids_spi, .name = "SPI_B" },
    .{ .base = 0x4025_E000, .stride = 0x100, .ids = &ids_riic, .name = "RIIC" },
    .{ .base = 0x4035_F000, .stride = 0x214, .ids = &ids_i3c, .name = "I3C" },
    .{ .base = 0x4022_1000, .stride = 0x100, .ids = &ids_agt, .name = "AGT" },
    .{ .base = 0x4032_2000, .stride = 0x100, .ids = &ids_gpt, .name = "GPT" },
    .{ .base = 0x4022_0000, .stride = 0x100, .ids = &ids_ulpt, .name = "ULPT" },
    .{ .base = 0x4023_3000, .stride = 0x100, .ids = &ids_dac, .name = "DAC_B" },
    .{ .base = 0x4025_D000, .stride = 0x100, .ids = &ids_ssie, .name = "SSIE" },
    .{ .base = 0x4021_2000, .stride = 0x100, .ids = &ids_poeg, .name = "POEG" },
    .{ .base = 0x4038_0000, .stride = 0x1920, .ids = &ids_canfd0, .name = "CANFD0" },
    .{ .base = 0x4038_2000, .stride = 0x1920, .ids = &ids_canfd1, .name = "CANFD1" },
    .{ .base = 0x4020_2400, .stride = 0x10, .ids = &ids_cac, .name = "CAC" },
    .{ .base = 0x4031_0000, .stride = 0x20, .ids = &ids_crc, .name = "CRC" },
    .{ .base = 0x4031_1000, .stride = 0x20, .ids = &ids_doc, .name = "DOC" },
    .{ .base = 0x4034_8000, .stride = 0x100, .ids = &ids_ceu, .name = "CEU" },
    .{ .base = 0x4025_6000, .stride = 0x400, .ids = &ids_pdm, .name = "PDM-IF" },
    .{ .base = 0x4033_8000, .stride = 0x2224, .ids = &ids_adc, .name = "ADC_B" },
    .{ .base = 0x4025_2000, .stride = 0x200, .ids = &ids_sdhi, .name = "SDHI0" },
    .{ .base = 0x4026_8000, .stride = 0x200, .ids = &ids_xspi, .name = "XSPI0" },
    .{ .base = 0x4044_4000, .stride = 0x104, .ids = &ids_drw, .name = "DRW" },
};

const Owner = struct {
    family: *const Family,
    index: usize,
};

fn ownerOf(address: u32) ?Owner {
    for (&families) |*family| {
        const offset = @as(u64, address) -% family.base;
        if (address >= family.base and offset < family.span()) {
            return .{ .family = family, .index = @intCast(offset / family.stride) };
        }
    }
    return null;
}

/// The MSTPCRA..E shadow, the gate it implies, and what the gate dropped.
pub const Mstp = struct {
    /// The security attribution words next door, or null on a board that
    /// has none, in which case nothing is delegated.
    attribution: ?*const pscu.Unit = null,
    /// The bus, read for which alias a store came through. Null treats
    /// every store as Secure, as a board without one always did.
    bus: ?*const periph.Bus = null,
    /// Secure stores whose bits the attribution mask refused to move.
    masked_writes: u32 = 0,
    /// The OCTACLK watch, or null on a board that has none. MSTPB16/B17 are
    /// the only bits in this window whose release has a precondition
    /// somewhere else (HUM Ch 11.2.7 Note 3).
    octa: ?*octaclk.Octa = null,
    regs: [reg_count]u32 = .{ reset_a, reset_rest, reset_rest, reset_rest, reset_rest },
    gated_reads: u32 = 0,
    gated_writes: u32 = 0,
    last_gated: []const u8 = "-",
    /// The same drops, split by peripheral, so the end of the run can ask the
    /// gate again and tell a probe from a driver that never ungated.
    dropped: drops.Log = .{},

    pub fn reset(self: *Mstp) void {
        self.* = .{};
    }

    /// True while the peripheral owning `address` is unclocked. An address no
    /// family covers is never stopped, so an ungated or unported block answers
    /// exactly as it did before this slice.
    pub fn stopped(self: *const Mstp, address: u32) bool {
        const owner = ownerOf(address) orelse return false;
        const packed_id = owner.family.ids[owner.index];
        const register = packed_id >> 8;
        const bit: u5 = @intCast(packed_id & 0x1F);
        if (register >= reg_count) return false;
        return (self.regs[register] & (@as(u32, 1) << bit)) != 0;
    }

    /// Record an access the gate dropped, so the end of the run can say so.
    pub fn note(self: *Mstp, address: u32, access: periph.Access) void {
        const name = if (ownerOf(address)) |owner| owner.family.name else "-";
        self.last_gated = name;
        switch (access) {
            .read => {
                self.gated_reads += 1;
                self.dropped.noteRead(name, address);
            },
            .write => {
                self.gated_writes += 1;
                self.dropped.noteWrite(name, address);
            },
        }
    }

    pub fn clean(self: *const Mstp) bool {
        return self.gated_reads == 0 and self.gated_writes == 0;
    }

    /// The drops split by whether the peripheral is still stopped NOW. An
    /// image that pokes a dead window to prove it is dead, then clears the
    /// bit, drops exactly what a driver that never ungated drops; only the
    /// gate afterwards tells them apart, so it is asked here and not earlier.
    pub fn verdict(self: *const Mstp) drops.Verdict {
        return self.dropped.verdict(self, stillStopped);
    }

    /// Read the shadow, so the read-back the firmware is required to do after
    /// changing a bit (HUM Ch 11.2.6 Note 2 p 443) sees what it just wrote.
    pub fn readReg(self: *const Mstp, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        var value: u32 = 0;
        var i: u32 = 0;
        while (i < width) : (i += 1) {
            const byte = offset + i;
            if (byte >= win_span) continue;
            const shift: u5 = @intCast((byte % 4) * 8);
            const taken = (self.regs[byte / 4] >> shift) & 0xFF;
            value |= taken << @as(u5, @intCast(i * 8));
        }
        return value;
    }

    /// Fold a write of any width into the shadow: clearing a bit ungates that
    /// peripheral, setting it gates the peripheral again.
    pub fn applyWrite(self: *Mstp, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        var i: u32 = 0;
        while (i < width) : (i += 1) {
            const byte = offset + i;
            if (byte >= win_span) break;
            const shift: u5 = @intCast((byte % 4) * 8);
            const incoming = (value >> @as(u5, @intCast(i * 8))) & 0xFF;
            const register = &self.regs[byte / 4];
            // A delegated bit is owned by the Non-secure alias: the store
            // names it, and it does not move.
            const writable = self.movable(byte / 4) & (@as(u32, 0xFF) << shift);
            if (writable == 0) {
                self.masked_writes +%= 1;
                continue;
            }
            const before = register.*;
            register.* = (before & ~writable) | ((incoming << shift) & writable);
            if ((@as(u32, 0xFF) << shift) != writable) self.masked_writes +%= 1;
            self.noteOspi(byte / 4, before, register.*);
        }
    }

    /// MSTPB16 and MSTPB17 uncover the OSPI, and HUM Ch 11.2.7 Note 3 says
    /// they must be written after OCTACLK is stable. Only the stopped ->
    /// running edge is the release; re-gating and a store that changes
    /// nothing are not.
    fn noteOspi(self: *Mstp, register: usize, before: u32, after: u32) void {
        if (register != octaclk.ospi_register) return;
        const unit = self.octa orelse return;
        const freed = before & ~after & octaclk.ospi_bits;
        if (freed == 0) return;
        unit.release();
    }

    /// The bits of one MSTPCR register the store being served may move. A
    /// Secure store moves what was not delegated. A store through the
    /// Non-secure alias moves the delegated bits too: they are its own. The
    /// silicon also ignores a Non-secure store to a Secure-owned bit; that
    /// is not modelled, so such a store still lands, as it always has.
    fn movable(self: *const Mstp, register: usize) u32 {
        const bus = self.bus orelse return ~self.delegated(register);
        return if (bus.nonsecure) 0xFFFF_FFFF else ~self.delegated(register);
    }

    /// The bits of one MSTPCR register that a Secure store cannot move.
    fn delegated(self: *const Mstp, register: usize) u32 {
        const words = self.attribution orelse return 0;
        return words.nonsecureMask(register);
    }

    fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
        const self: *Mstp = @ptrCast(@alignCast(context));
        return self.readReg(address, width);
    }

    fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
        const self: *Mstp = @ptrCast(@alignCast(context));
        self.applyWrite(address, width, value);
    }

    fn stillStopped(context: *const anyopaque, address: u32) bool {
        const self: *const Mstp = @ptrCast(@alignCast(context));
        return self.stopped(address);
    }

    fn stoppedThunk(context: *anyopaque, address: u32) bool {
        const self: *Mstp = @ptrCast(@alignCast(context));
        return self.stopped(address);
    }

    fn noteThunk(context: *anyopaque, address: u32, access: periph.Access) void {
        const self: *Mstp = @ptrCast(@alignCast(context));
        self.note(address, access);
    }

    /// The MSTPCRA..E window itself, as a bus block.
    pub fn block(self: *Mstp) periph.Block {
        return .{
            .name = "MSTP",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }

    /// The gate the bus consults before it answers anything else.
    pub fn gate(self: *Mstp) periph.Gate {
        return .{ .context = self, .stoppedFn = stoppedThunk, .noteFn = noteThunk };
    }
};
