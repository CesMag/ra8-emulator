//! COMA's bring-up words (RA8EMU-291 slice 3): RIC, RRC and RCEC at the
//! base of the common agent, 0x403C_9000.
//!
//! Offsets and bits are the firmware's ra8_coma_offset_t / ra8_coma_bit_t
//! (ra8_ether_regs.h): RIC +0x000, RRC +0x004 (RR bit 0), RCEC +0x008
//! (RCE bit 16, ACE bits 6:0). The same header's r_coma_regs_t names these
//! offsets CTRL/STS/IE; the driver writes them through the enum, so that is
//! the layout modelled. CABPIRM at +0x140 stays in gateway.zig's Pool.
//!
//! RRC.RR resets the switch IP. The driver pulses it (1, then 0) before
//! enabling the clocks; the model counts each rising edge and holds the word
//! as written. Nothing else in the cluster is reset by it. RIC and RCEC read
//! back what was written.
const periph = @import("../registry.zig");
const lanes = @import("../lanes.zig");
const regs = @import("regs.zig");

pub const off = struct {
    pub const ric: u32 = 0x000;
    pub const rrc: u32 = 0x004;
    pub const rcec: u32 = 0x008;
    pub const span: u32 = 0x00C;
};

pub const bit = struct {
    pub const rr: u32 = 1 << 0;
    pub const rce: u32 = 1 << 16;
    pub const ace_mask: u32 = 0x7F;
};

pub const Coma = struct {
    base: u32 = regs.cluster.coma,
    /// RIC, RRC and RCEC, in offset order.
    words: [3]u32 = .{ 0, 0, 0 },
    /// RRC.RR going from 0 to 1.
    resets: u32 = 0,
    writes: u32 = 0,

    pub fn quiet(self: *const Coma) bool {
        return self.writes == 0;
    }

    pub fn clockEnabled(self: *const Coma) bool {
        return self.words[2] & bit.rce != 0;
    }

    pub fn read(self: *Coma, address: u32, width: u3) u32 {
        const offset = address -% self.base;
        if (offset >= off.span) return 0;
        return lanes.part(self.words[offset / 4], offset & 0x3, width);
    }

    pub fn write(self: *Coma, address: u32, width: u3, value: u32) void {
        const offset = address -% self.base;
        if (offset >= off.span) return;
        self.writes +%= 1;
        const slot = &self.words[offset / 4];
        const next = lanes.merge(slot.*, offset & 0x3, width, value);
        if (offset / 4 == off.rrc / 4 and slot.* & bit.rr == 0 and next & bit.rr != 0) self.resets += 1;
        slot.* = next;
    }

    pub fn block(self: *Coma) periph.Block {
        return .{
            .name = "COMA",
            .base = self.base,
            .size = off.span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Coma = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Coma = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
