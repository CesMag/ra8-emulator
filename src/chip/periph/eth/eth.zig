//! One R-Switch port: the ETHA agent's mode machine and the RMAC's MDIO
//! window onto the PHY behind it.
//!
//! A port is two register windows a thousand bytes apart, so it hands the bus
//! two blocks rather than claiming the gap between them. Everything else in
//! the port's two kilobytes is configuration the driver writes and reads back,
//! which the bus already does for an address nothing models.
//!
//! Every register here is 32 bits, so an access narrower than a word is the
//! `lanes.zig` rule: a read is served from the word the address lands in and
//! then cut, and a store is merged into that word so the lanes it does not
//! name keep what they had.
//!
//! BOTH WINDOWS ARE DARK UNTIL THE ESWM POWER DOMAIN IS ON. The R-Switch sits
//! in its own switchable domain, gated off at reset behind PDCTRESWM, so this
//! port asks src/chip/periph/pdctr.zig before it answers anything. ra8_cgc_eswclk.c
//! states the hardware behaviour outright: "every per-port RMAC / ETHA
//! register read returns 0 and writes are silently dropped until
//! PDCTRESWM.PDDE = 0", marked as observed on EK-RA8D2 hardware. Without the
//! question a firmware that never powered the domain drives a whole port here,
//! walks its mode machine up to OPERATION and reads its own MAC address back,
//! and does none of it on the bench. The read answering zero is the half that
//! bites hardest: the mode machine reads DISABLE forever, so a driver polling
//! for CONFIG spins rather than failing.
//!
//! A port with no domain attached is ungated, which is what a test about the
//! mode machine or the MDIO bus wants; src/board/net.zig wires the real one in
//! when it puts the cluster on the bus.
const std = @import("std");
const lanes = @import("../lanes.zig");
const periph = @import("../registry.zig");
pub const regs = @import("regs.zig");
const eth_mode = @import("mode.zig");
pub const mode = eth_mode;
const eth_line = @import("line.zig");
const eth_mac = @import("mac.zig");
pub const mac = eth_mac;
const eth_tas = @import("tas.zig");
const eth_cbs = @import("cbs.zig");
const pdctr = @import("../pdctr.zig");

/// The perfect-match address, reached as `eth.mac_address` by a caller that
/// already has the port.
pub const mac_address = eth_mac;
/// EATDQDC and the error-interrupt groups: agent.zig.
pub const agent = @import("agent.zig");
/// MFWD control and per-port forwarding words: forward.zig.
pub const forward = @import("forward.zig");
/// Ancillary Ethernet setup words touched by GWCA open.
pub const open_regs = @import("open_regs.zig");
/// COMA RIC, RRC and RCEC: coma.zig.
pub const coma = @import("coma.zig");
pub const desc = @import("desc.zig");
pub const dma = @import("dma.zig");
pub const gateway = @import("gateway.zig");
pub const queue = @import("queue.zig");
/// The MDIO bus and the wire the board connects: line.zig.
pub const line = eth_line;
/// TAS gate-list RAM and indirect access registers.
pub const tas = eth_tas;
/// CBS admin and operational registers.
pub const cbs = eth_cbs;

pub const Port = struct {
    /// Where this port's two agents answer. A board fact, so it is set when
    /// the board populates the port.
    etha_base: u32,
    rmac_base: u32,
    mode: eth_mode.Machine = .{},
    /// The MDIO bus to this port's PHY, a board part the board wires in.
    /// Null for a port with nothing on its bus.
    mdio: ?eth_line.Mdio = null,
    /// The last management frame, as MPSM reads back.
    mpsm: u32 = 0,
    /// MRMAC0/MRMAC1, which only take a store while this port is in CONFIG.
    mac: eth_mac.Address = .{},
    tas_ram: eth_tas.Tas = .{ .base = 0 },
    cbs_regs: eth_cbs.Cbs = .{ .base = 0 },
    /// The ESWM power domain, or null for a port nothing gated.
    domain: ?*const pdctr.Pdctr = null,
    /// Stores dropped, and reads served as zero, with the domain gated off.
    dropped_unpowered: u32 = 0,
    dark_reads: u32 = 0,

    pub fn init(etha_base: u32, rmac_base: u32) Port {
        return .{
            .etha_base = etha_base,
            .rmac_base = rmac_base,
            .tas_ram = eth_tas.Tas.init(etha_base),
            .cbs_regs = eth_cbs.Cbs.init(etha_base),
        };
    }

    /// Whether this port's windows answer at all. A port with no domain model
    /// attached is ungated: the gate is a board fact, and a unit test that is
    /// not about it should not have to build one.
    fn powered(self: *const Port) bool {
        const domain = self.domain orelse return true;
        return domain.powered();
    }

    /// A read reaching a dark window: zero, and counted. Separated from the
    /// store side because the two failures look nothing alike to a driver.
    fn dark(self: *Port) u32 {
        self.dark_reads +%= 1;
        return 0;
    }

    /// EAMC reads back the command; EAMS reports where the machine is.
    pub fn ethaRead(self: *Port, address: u32, width: u3) u32 {
        if (!self.powered()) return self.dark();
        const offset = address -% self.etha_base;
        const whole: u32 = switch (lanes.word(offset)) {
            regs.etha.eamc, regs.etha.eams => self.mode.status(),
            else => 0,
        };
        return lanes.part(whole, lanes.lane(offset), width);
    }

    pub fn ethaWrite(self: *Port, address: u32, width: u3, value: u32) void {
        if (!self.powered()) {
            self.dropped_unpowered +%= 1;
            return;
        }
        const offset = address -% self.etha_base;
        // EAMS is the machine's own to report. A store there moves nothing.
        if (lanes.word(offset) != regs.etha.eamc) return;
        const at = lanes.lane(offset);
        // OPC is the bottom of the word, so a store that reaches none of its
        // lanes carries no command however wide the rest of it is.
        if (lanes.named(at, width) & regs.etha.opc_mask == 0) return;
        const asked = lanes.merge(self.mode.status(), at, width, value);
        self.mode.command(asked & regs.etha.opc_mask);
        self.tas_ram.enterMode(self.mode.mode);
    }

    pub fn tasRead(self: *Port, address: u32, width: u3) u32 {
        if (!self.powered()) return self.dark();
        return self.tas_ram.read(address, width);
    }

    pub fn tasWrite(self: *Port, address: u32, width: u3, value: u32) void {
        if (!self.powered()) {
            self.dropped_unpowered +%= 1;
            return;
        }
        self.tas_ram.write(address, width, value);
    }

    pub fn cbsRead(self: *Port, address: u32, width: u3) u32 {
        if (!self.powered()) return self.dark();
        return self.cbs_regs.read(address, width);
    }

    pub fn cbsWrite(self: *Port, address: u32, width: u3, value: u32) void {
        if (!self.powered()) {
            self.dropped_unpowered +%= 1;
            return;
        }
        self.cbs_regs.write(address, width, value);
    }

    pub fn rmacRead(self: *Port, address: u32, width: u3) u32 {
        if (!self.powered()) return self.dark();
        const offset = address -% self.rmac_base;
        if (lanes.word(offset) != regs.rmac.mpsm) return 0;
        return lanes.part(self.mpsm, lanes.lane(offset), width);
    }

    /// PRD is the top half of MPSM and the control fields are the bottom, so
    /// a driver that builds a frame in two halfword stores only has a whole
    /// frame once the second one lands. The merge is what makes the order of
    /// those two stores stop mattering, and PSME in the merged word is what
    /// decides whether anything goes out on the wire.
    pub fn rmacWrite(self: *Port, address: u32, width: u3, value: u32) void {
        if (!self.powered()) {
            self.dropped_unpowered +%= 1;
            return;
        }
        const offset = address -% self.rmac_base;
        if (lanes.word(offset) != regs.rmac.mpsm) return;
        const asked = lanes.merge(self.mpsm, lanes.lane(offset), width, value);
        if (asked & regs.rmac.psme == 0) {
            // No frame asked for: the register just holds what was written.
            self.mpsm = asked;
            return;
        }
        self.mpsm = if (self.mdio) |bus| bus.transact(asked) else eth_line.unanswered(asked);
    }

    /// MRMAC0/MRMAC1. The port's own mode decides whether the store lands,
    /// which is why the pair is answered here rather than by a block of its
    /// own holding no mode.
    pub fn macRead(self: *Port, at: u32, width: u3) u32 {
        if (!self.powered()) return self.dark();
        return self.mac.read(at -% self.rmac_base, width);
    }

    pub fn macWrite(self: *Port, at: u32, width: u3, value: u32) void {
        if (!self.powered()) {
            self.dropped_unpowered +%= 1;
            return;
        }
        self.mac.write(self.mode.mode, at -% self.rmac_base, width, value);
    }

    pub fn quiet(self: *const Port) bool {
        return self.mode.quiet() and self.mac.quiet() and
            self.tas_ram.quiet() and self.cbs_regs.quiet() and
            self.dropped_unpowered == 0 and self.dark_reads == 0;
    }

    pub fn ethaBlock(self: *Port) periph.Block {
        return .{
            .name = "ETHA",
            .base = self.etha_base,
            .size = regs.etha.mode_span,
            .context = self,
            .readFn = ethaReadThunk,
            .writeFn = ethaWriteThunk,
        };
    }

    pub fn tasBlock(self: *Port) periph.Block {
        return .{
            .name = "ETHA-TAS",
            .base = self.etha_base + eth_tas.reg.start,
            .size = eth_tas.reg.span,
            .context = self,
            .readFn = tasReadThunk,
            .writeFn = tasWriteThunk,
        };
    }

    pub fn cbsBlock(self: *Port) periph.Block {
        return .{
            .name = "ETHA-CBS",
            .base = self.etha_base + eth_cbs.off.admin_enable,
            .size = eth_cbs.off.span,
            .context = self,
            .readFn = cbsReadThunk,
            .writeFn = cbsWriteThunk,
        };
    }

    pub fn macBlock(self: *Port) periph.Block {
        return .{
            .name = "RMAC-MAC",
            .base = self.rmac_base + eth_mac.off.mrmac0,
            .size = eth_mac.off.span,
            .context = self,
            .readFn = macReadThunk,
            .writeFn = macWriteThunk,
        };
    }

    pub fn rmacBlock(self: *Port) periph.Block {
        return .{
            .name = "RMAC",
            .base = self.rmac_base,
            .size = regs.rmac.mpsm_span,
            .context = self,
            .readFn = rmacReadThunk,
            .writeFn = rmacWriteThunk,
        };
    }
};

fn ethaReadThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Port = @ptrCast(@alignCast(context));
    return self.ethaRead(address, width);
}

fn ethaWriteThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Port = @ptrCast(@alignCast(context));
    self.ethaWrite(address, width, value);
}

fn tasReadThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Port = @ptrCast(@alignCast(context));
    return self.tasRead(address, width);
}

fn tasWriteThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Port = @ptrCast(@alignCast(context));
    self.tasWrite(address, width, value);
}

fn cbsReadThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Port = @ptrCast(@alignCast(context));
    return self.cbsRead(address, width);
}

fn cbsWriteThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Port = @ptrCast(@alignCast(context));
    self.cbsWrite(address, width, value);
}

fn rmacReadThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Port = @ptrCast(@alignCast(context));
    return self.rmacRead(address, width);
}

fn rmacWriteThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Port = @ptrCast(@alignCast(context));
    self.rmacWrite(address, width, value);
}

fn macReadThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Port = @ptrCast(@alignCast(context));
    return self.macRead(address, width);
}

fn macWriteThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Port = @ptrCast(@alignCast(context));
    self.macWrite(address, width, value);
}
