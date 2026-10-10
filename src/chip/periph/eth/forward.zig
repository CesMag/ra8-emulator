//! MFWD, the R-Switch forwarding engine (RA8EMU-291 slice 2): its control
//! words and the per-port forwarding configuration.
//!
//! Offsets are the firmware's, from the MFWD base 0x403C_0000:
//!   MFWD_CTRL +0x00, MFWD_STS +0x04, MFWD_IE +0x08, MFWD_ICLR +0x0C
//!     (r_mfwd_regs_t in ra8_ether_regs.h)
//!   FWPBFC0[p] +0x4A00 + 0x10*p, FWPBFCSDC0[p] +0x4A04 + 0x10*p, p = 0..2
//!     (ra8_eth_mfwd.c, quoting the CMSIS R7KA8D2KF_core0.h layout)
//! eth_l3switch_forward_demo writes all of them; unmodelled, the stores fell
//! to the sparse bus.
//!
//! NOTHING IS FORWARDED BY THESE WORDS. PBDV (FWPBFC0 bits 6:0, the ports a
//! frame may go to) and PBCSD (FWPBFCSDC0 bits 6:0, the host queue) are held
//! as written so the driver's read-modify-write keeps its other bits, but the
//! frames the gateway moves take no route from them.
//!
//! STATUS: MFWD_STS holds what was written and MFWD_ICLR clears the bits it
//! is given, so the driver's clear sequence ends with STS 0. The model raises
//! no forwarding events, so nothing ever sets a bit on its own. ICLR reads 0.
const periph = @import("../registry.zig");
const lanes = @import("../lanes.zig");

pub const base: u32 = 0x403C_0000;

pub const off = struct {
    pub const ctrl: u32 = 0x00;
    pub const sts: u32 = 0x04;
    pub const ie: u32 = 0x08;
    pub const iclr: u32 = 0x0C;
    pub const control_span: u32 = 0x10;
    pub const fwpbfc0: u32 = 0x4A00;
    pub const fwpbfcsdc0: u32 = 0x4A04;
    pub const port_stride: u32 = 0x10;
    /// FWPBFC and FWPBFCSDC: the two words of one port's slot.
    pub const port_span: u32 = 0x8;
    pub const port_count: usize = 3;
    pub const fwpc10: u32 = 0x104;
    pub const fwpc11: u32 = 0x114;
    pub const fwpc12: u32 = 0x124;
    pub const dde: u32 = 1;
};

pub const Forward = struct {
    ctrl: u32 = 0,
    sts: u32 = 0,
    ie: u32 = 0,
    /// FWPBFC0 and FWPBFCSDC0 for ports 0, 1 and the host port.
    ports: [off.port_count][2]u32 = @splat(.{ 0, 0 }),
    /// FWPC10/11/12.DDE selects the extended descriptor format per agent.
    fwpc: [3]u32 = .{ 0, 0, 0 },
    /// Stores that landed anywhere here.
    writes: u32 = 0,

    pub fn quiet(self: *const Forward) bool {
        return self.writes == 0;
    }

    fn slot(self: *Forward, offset: u32) ?*u32 {
        const aligned = offset & ~@as(u32, 0x3);
        switch (aligned) {
            off.ctrl => return &self.ctrl,
            off.sts => return &self.sts,
            off.ie => return &self.ie,
            off.fwpc10 => return &self.fwpc[0],
            off.fwpc11 => return &self.fwpc[1],
            off.fwpc12 => return &self.fwpc[2],
            else => {},
        }
        if (aligned < off.fwpbfc0) return null;
        const inside = aligned - off.fwpbfc0;
        const port = inside / off.port_stride;
        const word = inside % off.port_stride;
        if (port >= off.port_count or word >= off.port_span) return null;
        return &self.ports[port][word / 4];
    }

    pub fn read(self: *Forward, address: u32, width: u3) u32 {
        const offset = address -% base;
        const found = self.slot(offset) orelse return 0;
        return lanes.part(found.*, offset & 0x3, width);
    }

    pub fn write(self: *Forward, address: u32, width: u3, value: u32) void {
        const offset = address -% base;
        self.writes +%= 1;
        if (offset & ~@as(u32, 0x3) == off.iclr) {
            self.sts &= ~lanes.merge(0, offset & 0x3, width, value);
            return;
        }
        const found = self.slot(offset) orelse return;
        found.* = lanes.merge(found.*, offset & 0x3, width, value);
    }

    /// The control window and one window per port slot.
    pub fn blocks(self: *Forward) [2 + off.port_count]periph.Block {
        var out: [2 + off.port_count]periph.Block = undefined;
        out[0] = self.window("MFWD", base, off.control_span);
        out[1] = self.window("MFWD-FWPC", base + off.fwpc10, 0x24);
        for (0..off.port_count) |p| {
            const at = base + off.fwpbfc0 + off.port_stride * @as(u32, @intCast(p));
            out[2 + p] = self.window("MFWD-FWPBFC", at, off.port_span);
        }
        return out;
    }

    fn window(self: *Forward, name: []const u8, at: u32, size: u32) periph.Block {
        return .{
            .name = name,
            .base = at,
            .size = size,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Forward = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Forward = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
