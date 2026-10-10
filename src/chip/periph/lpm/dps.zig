//! The deep-standby cancel registers (RA8EMU-308): which sources may end
//! deep software standby, on which edge, and which one did.
//!
//! Offsets are ra8_lpm_regs.h's, on the SYSC page 0x4001_E000. Each is an
//! 8-bit register on a 4-byte stride:
//!   DPSIER0..3  +0xA08/0C/10/14  cancel-source enables, held as written
//!   DPSIFR0..3  +0xA18/1C/20/24  cancel-source flags
//!   DPSIEGR0..2 +0xA28/2C/30     edge selects, held as written
//! ra8_lpm clears the enables and flags before it arms deep standby, so
//! lpm_deep_standby_1/2/3_demo all wrote DPSIER2 and DPSIFR2 into nothing.
//!
//! FLAGS ONLY FALL. A DPSIFR bit is cleared by writing 0 to it; writing 1
//! keeps whatever is there. Nothing sets one yet, because no cancel source
//! is modelled, so the flags read 0 from reset.
//!
//! PRCR: the HUM puts these behind PRC1. lpm.zig's bytes ask the protect
//! register first; these do not yet, so a store with PRC1 clear still lands.
const periph = @import("../registry.zig");
const lanes = @import("../lanes.zig");

pub const base: u32 = 0x4001_EA08;
pub const stride: u32 = 4;
pub const enable_count: usize = 4;
pub const flag_count: usize = 4;
pub const edge_count: usize = 3;
pub const count: usize = enable_count + flag_count + edge_count;
pub const span: u32 = stride * count;

pub const Kind = enum { enable, flag, edge };

/// The register an address names: its kind and its index within that kind.
pub const Slot = struct { kind: Kind, index: usize };

pub fn slotOf(address: u32) ?Slot {
    const offset = address -% base;
    if (offset >= span or offset % stride != 0) return null;
    const n: usize = offset / stride;
    if (n < enable_count) return .{ .kind = .enable, .index = n };
    if (n < enable_count + flag_count) return .{ .kind = .flag, .index = n - enable_count };
    return .{ .kind = .edge, .index = n - enable_count - flag_count };
}

pub fn addressOf(kind: Kind, index: usize) u32 {
    const first: usize = switch (kind) {
        .enable => 0,
        .flag => enable_count,
        .edge => enable_count + flag_count,
    };
    return base + stride * @as(u32, @intCast(first + index));
}

pub const Dps = struct {
    /// DPSIER0..3, DPSIFR0..3, DPSIEGR0..2 in address order.
    bytes: [count]u8 = @splat(0),
    writes: u32 = 0,

    pub fn quiet(self: *const Dps) bool {
        return self.writes == 0;
    }

    pub fn read(self: *Dps, address: u32, width: u3) u32 {
        _ = width;
        const offset = address -% base;
        if (offset >= span or offset % stride != 0) return 0;
        return self.bytes[offset / stride];
    }

    pub fn write(self: *Dps, address: u32, width: u3, value: u32) void {
        const slot = slotOf(address) orelse return;
        const byte: u8 = @truncate(lanes.merge(0, 0, width, value));
        self.writes +%= 1;
        const at = &self.bytes[(address -% base) / stride];
        at.* = switch (slot.kind) {
            .flag => at.* & byte,
            .enable, .edge => byte,
        };
    }

    pub fn block(self: *Dps) periph.Block {
        return .{
            .name = "LPM deep-standby cancel",
            .base = base,
            .size = span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Dps = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Dps = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
