//! CPSCU SRAM attribution: SRAMSAR, SRAMSABAR0..3 and SRAMESAR (RA8EMU-230).
//!
//! These words split each SRAM bank into a Secure part and a Non-Secure part
//! (SRAMSABARn, HUM Ch 58.2.1), give the per-bank register sets and SRAMWTSC
//! to the Non-Secure world (SRAMSAR, 58.2.2), and do the same for the ECC
//! region (SRAMESAR, 58.2.3). secure_boot_ns_hil's Secure boot writes all four
//! boundaries through ra8_sram_set_boundary before it enters the Non-Secure
//! image. Unmodelled, those stores fell to the sparse bus, whose cells read
//! back 0 and 0xFFFF_FFFF in turn.
//!
//! THREE WINDOWS, NOT ONE. The words sit at CPSCU offsets 0x010, 0x400..0x40C
//! and 0x510, and cpscu.zig, dtc/sar.zig and ipc/attr.zig already hold the
//! words between them, so each range is a block of its own on the bus.
//!
//! WRITABLE BITS come from the firmware's ra8_sram_regs.h, which quotes the
//! HUM pages: SRAMSAR 0x10F (SA0..SA3 and WTSA), SRAMSABARn 0x001F_E000 (the
//! 8 KB-granular boundary, b20..b13), SRAMESAR 0x1. Bits outside a mask are
//! dropped on the way in and read back zero.
//!
//! RESET AND THE GATE ARE NOT MODELLED FROM THE HUM. Every word resets to 0
//! and every store lands, whether or not PRCR_S.PRC4 is open. The rest of
//! CPSCU is PRC4-gated (cpscu.zig); whether these words are too was not read
//! from the manual, so RA8EMU-230 carries it as an open question rather than
//! this file inventing a refusal. Recorded, not enforced: nothing here stops
//! a Non-Secure access to SRAM a boundary left Secure.
const periph = @import("../registry.zig");
const lanes = @import("../lanes.zig");

pub const cpscu_base: u32 = 0x4000_8000;

pub const sar_address: u32 = cpscu_base + 0x010;
pub const sabar_base: u32 = cpscu_base + 0x400;
pub const esar_address: u32 = cpscu_base + 0x510;
pub const bank_count: usize = 4;

pub const sar_mask: u32 = 0x0000_010F;
pub const sabar_mask: u32 = 0x001F_E000;
pub const esar_mask: u32 = 0x0000_0001;

pub const Unit = struct {
    sar: u32 = 0,
    sabar: [bank_count]u32 = @splat(0),
    esar: u32 = 0,
    /// Stores that landed on any of the words.
    writes: u32 = 0,

    pub fn quiet(self: *const Unit) bool {
        return self.writes == 0;
    }

    /// The word an address names and the bits it keeps, or null for none.
    fn slot(self: *Unit, address: u32) ?struct { word: *u32, mask: u32 } {
        const aligned = address & ~@as(u32, 0x3);
        if (aligned == sar_address) return .{ .word = &self.sar, .mask = sar_mask };
        if (aligned == esar_address) return .{ .word = &self.esar, .mask = esar_mask };
        if (aligned >= sabar_base and aligned < sabar_base + 4 * bank_count) {
            return .{ .word = &self.sabar[(aligned - sabar_base) / 4], .mask = sabar_mask };
        }
        return null;
    }

    pub fn read(self: *Unit, address: u32, width: u3) u32 {
        const found = self.slot(address) orelse return 0;
        return lanes.part(found.word.*, address & 0x3, width);
    }

    pub fn write(self: *Unit, address: u32, width: u3, value: u32) void {
        const found = self.slot(address) orelse return;
        found.word.* = lanes.merge(found.word.*, address & 0x3, width, value) & found.mask;
        self.writes +%= 1;
    }

    /// SRAMSAR, SRAMSABAR0..3 and SRAMESAR, one block each window.
    pub fn blocks(self: *Unit) [3]periph.Block {
        return .{
            self.block("CPSCU-SRAMSAR", sar_address, 4),
            self.block("CPSCU-SRAMSABAR", sabar_base, 4 * bank_count),
            self.block("CPSCU-SRAMESAR", esar_address, 4),
        };
    }

    fn block(self: *Unit, name: []const u8, base: u32, size: u32) periph.Block {
        return .{
            .name = name,
            .base = base,
            .size = size,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Unit = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Unit = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
