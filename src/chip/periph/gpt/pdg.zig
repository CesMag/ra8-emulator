//! PDG: the PWM output delay generator in front of GPT channels 0..3
//! (RA8EMU-315).
//!
//! Map from ra8_pdg_regs.h (HUM Ch 23.2, p 1154-1158), base 0x4032_4000:
//!
//!   GTDLYCR   +0x00 (16b)  DLLEN b0, DLYRST b1, FRANGE b9:8
//!   GTDLYCR2  +0x02 (16b)  DLYBS b3:0 (1 = delay applied), DLYEN b11:8
//!                          (inverted: 1 = that channel's line powered off)
//!   GTDLYRnA  +0x18+4n     rising-edge code for GTIOCnA, DLY b6:0
//!   GTDLYRnB  +0x1A+4n     rising-edge code for GTIOCnB
//!   GTDLYFnA  +0x28+4n     falling-edge code for GTIOCnA
//!   GTDLYFnB  +0x2A+4n     falling-edge code for GTIOCnB
//!
//! Each register keeps only its writable bits and reads back what landed;
//! the delay cells drop bits 15:7 as the header says they read as 0. Nothing
//! here delays an edge: the GPT model has no sub-cycle timing to shift, so
//! this block is state for the driver's read-backs, the board view and tests.
//! The bring-up sequence (DLYRST with DLLEN, the 20 us lock, then release) is
//! counted so a run report can tell a locked-and-released DLL from one left
//! in reset, which is what ra8_pdg's is-initialized check reads.
//!
//! RESET STATE: the tree states 0 for the delay cells (ra8_pdg_deinit wipes
//! them "back to the post-reset value of 0") and nothing for the two control
//! registers; this model starts them at 0 as well.
const periph = @import("../registry.zig");
const lanes = @import("../lanes.zig");

pub const base: u32 = 0x4032_4000;
pub const span: u32 = 0x30;
pub const channels: usize = 4;

pub const off = struct {
    pub const gtdlycr: u32 = 0x00;
    pub const gtdlycr2: u32 = 0x02;
    pub const rise: u32 = 0x18;
    pub const fall: u32 = 0x28;
};

pub const mask = struct {
    pub const dllen: u16 = 1 << 0;
    pub const dlyrst: u16 = 1 << 1;
    pub const frange: u16 = 0x3 << 8;
    pub const gtdlycr: u16 = dllen | dlyrst | frange;
    pub const dlybs: u16 = 0x000F;
    pub const dlyen: u16 = 0x0F00;
    pub const gtdlycr2: u16 = dlybs | dlyen;
    pub const dly: u16 = 0x007F;
};

pub const Edge = enum { rise, fall };
pub const Pin = enum { a, b };

pub const Pdg = struct {
    gtdlycr: u16 = 0,
    gtdlycr2: u16 = 0,
    /// Delay codes by edge, then channel, then pin.
    codes: [2][channels][2]u16 = @splat(@splat(.{ 0, 0 })),
    writes: u32 = 0,
    /// Times the DLL left reset with DLLEN set: one per completed bring-up.
    releases: u32 = 0,

    pub fn init() Pdg {
        return .{};
    }

    pub fn quiet(self: *const Pdg) bool {
        return self.writes == 0;
    }

    /// DLL enabled and the circuit out of reset: ra8_pdg's own test.
    pub fn running(self: *const Pdg) bool {
        return self.gtdlycr & mask.dllen != 0 and self.gtdlycr & mask.dlyrst == 0;
    }

    pub fn frange(self: *const Pdg) u2 {
        return @truncate(self.gtdlycr >> 8);
    }

    /// Whether channel `n` has its delay applied rather than bypassed.
    pub fn applied(self: *const Pdg, n: usize) bool {
        return self.gtdlycr2 & (@as(u16, 1) << @intCast(n)) != 0;
    }

    pub fn code(self: *const Pdg, edge: Edge, n: usize, pin: Pin) u16 {
        return self.codes[@backingInt(edge)][n][@backingInt(pin)];
    }

    pub fn read(self: *const Pdg, address: u32, width: u3) u32 {
        const at = address - base;
        const word = at & ~@as(u32, 3);
        const value = (@as(u32, self.half(word + 2)) << 16) | self.half(word);
        return lanes.part(value, at - word, width);
    }

    pub fn write(self: *Pdg, address: u32, width: u3, value: u32) void {
        const at = address - base;
        self.writes +%= 1;
        var lane: u32 = 0;
        while (lane < width) : (lane += 2) {
            const shift: u5 = @intCast(lane * 8);
            self.store(at + lane, @truncate(value >> shift));
        }
    }

    fn half(self: *const Pdg, at: u32) u16 {
        if (at == off.gtdlycr) return self.gtdlycr;
        if (at == off.gtdlycr2) return self.gtdlycr2;
        const cell = slot(at) orelse return 0;
        return self.codes[cell.edge][cell.n][cell.pin];
    }

    fn store(self: *Pdg, at: u32, value: u16) void {
        if (at == off.gtdlycr) return self.storeControl(value);
        if (at == off.gtdlycr2) {
            self.gtdlycr2 = value & mask.gtdlycr2;
            return;
        }
        const cell = slot(at) orelse return;
        self.codes[cell.edge][cell.n][cell.pin] = value & mask.dly;
    }

    fn storeControl(self: *Pdg, value: u16) void {
        const held = self.gtdlycr & mask.dlyrst != 0;
        self.gtdlycr = value & mask.gtdlycr;
        if (held and self.running()) self.releases +%= 1;
    }

    pub fn block(self: *Pdg) periph.Block {
        return .{
            .name = "PDG",
            .base = base,
            .size = span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

const Slot = struct { edge: usize, n: usize, pin: usize };

/// Which delay cell a halfword offset names, if any.
fn slot(at: u32) ?Slot {
    if (at & 1 != 0) return null;
    const edge: usize = if (at >= off.rise and at < off.fall)
        0
    else if (at >= off.fall and at < off.fall + 4 * channels)
        1
    else
        return null;
    const rel = at - (if (edge == 0) off.rise else off.fall);
    return .{ .edge = edge, .n = rel / 4, .pin = (rel % 4) / 2 };
}

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Pdg = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Pdg = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
