//! ETHA agent registers beyond the mode pair (RA8EMU-291): the per-class TX
//! queue depth words and the three error-interrupt groups.
//!
//! Offsets are the firmware's ra8_etha_regs.h ra8_etha_off_t, from each
//! port's ETHA base (0x403C_A000, 0x403C_C000):
//!   EATDQDC0..7      +0x060..+0x07C  per-class queue depth configuration
//!   EAEIS/E/D 0..2   +0x500..+0x528  error IRQ status, enable, disable
//! eth_loopback and eth_tsn_tas_demo write both groups while bringing a port
//! up; unmodelled, the stores fell to the sparse bus.
//!
//! EAEIEn AND EAEIDn ARE A SET/CLEAR PAIR over one enable mask: a 1 written
//! to EAEIEn turns that error source on, a 1 written to EAEIDn turns it off,
//! and EAEIEn reads the mask back. EAEIDn reads 0. The driver writes all ones
//! to EAEIDn and then its own mask to EAEIEn (ra8_etha.c).
//!
//! NO ERRORS ARE RAISED. EAEISn reads 0 and a store to it changes nothing,
//! because the model has no queue overflow or frame error to report. The
//! queue depth words are held as written: nothing here limits a queue.
//!
//! The ESWM power domain gate that eth.zig applies to EAMC/EAMS is not
//! applied here. Recorded, not enforced.
const periph = @import("../registry.zig");
const lanes = @import("../lanes.zig");

pub const off = struct {
    pub const eatdqdc0: u32 = 0x060;
    pub const class_count: u32 = 8;
    pub const queue_span: u32 = class_count * 4;
    pub const eaeis0: u32 = 0x500;
    /// EAEIS, EAEIE and EAEID repeat every 0x10 for groups 0..2.
    pub const group_stride: u32 = 0x10;
    pub const group_count: u32 = 3;
    pub const error_span: u32 = 0x2C;
    /// Inside a group: status +0x0, enable +0x4, disable +0x8.
    pub const status: u32 = 0x0;
    pub const enable: u32 = 0x4;
    pub const disable: u32 = 0x8;
};

pub const Agent = struct {
    base: u32,
    depth: [off.class_count]u32 = @splat(0),
    enabled: [off.group_count]u32 = @splat(0),
    /// Stores that landed on either window.
    writes: u32 = 0,

    pub fn init(base: u32) Agent {
        return .{ .base = base };
    }

    pub fn quiet(self: *const Agent) bool {
        return self.writes == 0;
    }

    pub fn read(self: *Agent, address: u32, width: u3) u32 {
        const offset = address -% self.base;
        const lane = offset & 0x3;
        if (self.depthSlot(offset)) |slot| return lanes.part(slot.*, lane, width);
        const at = errorSlot(offset) orelse return 0;
        if (at.kind != off.enable) return 0;
        return lanes.part(self.enabled[at.group], lane, width);
    }

    pub fn write(self: *Agent, address: u32, width: u3, value: u32) void {
        const offset = address -% self.base;
        const lane = offset & 0x3;
        if (self.depthSlot(offset)) |slot| {
            slot.* = lanes.merge(slot.*, lane, width, value);
            self.writes +%= 1;
            return;
        }
        const at = errorSlot(offset) orelse return;
        const bits = lanes.merge(0, lane, width, value);
        const mask = &self.enabled[at.group];
        switch (at.kind) {
            off.enable => mask.* |= bits,
            off.disable => mask.* &= ~bits,
            else => {},
        }
        self.writes +%= 1;
    }

    fn depthSlot(self: *Agent, offset: u32) ?*u32 {
        if (offset < off.eatdqdc0 or offset >= off.eatdqdc0 + off.queue_span) return null;
        return &self.depth[(offset - off.eatdqdc0) / 4];
    }

    /// The queue depth window and the error-interrupt window.
    pub fn blocks(self: *Agent) [2]periph.Block {
        return .{
            self.window("ETHA-EATDQDC", off.eatdqdc0, off.queue_span),
            self.window("ETHA-EAEI", off.eaeis0, off.error_span),
        };
    }

    fn window(self: *Agent, name: []const u8, at: u32, size: u32) periph.Block {
        return .{
            .name = name,
            .base = self.base + at,
            .size = size,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

const Slot = struct { group: usize, kind: u32 };

fn errorSlot(offset: u32) ?Slot {
    if (offset < off.eaeis0 or offset >= off.eaeis0 + off.error_span) return null;
    const inside = offset - off.eaeis0;
    return .{
        .group = inside / off.group_stride,
        .kind = (inside % off.group_stride) & ~@as(u32, 0x3),
    };
}

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Agent = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Agent = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
