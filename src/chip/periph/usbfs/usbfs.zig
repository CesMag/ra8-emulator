//! The USBFS controller in device role: the window at 0x40250000 and the
//! registers a device driver reads back during bring-up.
//!
//! USBFS shares its register layout with USBHS (ra8_usb_regs.h), so the
//! offsets come from usbhs/regs.zig. What differs is the role: this side is
//! the device half of the board's USB loop, so what it reports is whether
//! VBUS is present and what the line looks like once the driver pulls D+ up.
//!
//! Everything the model does not own lands in a 16-bit shadow and reads back,
//! which is what the sparse register file did, minus the alternating
//! 0/all-ones answers to reads.
const std = @import("std");
const periph = @import("../registry.zig");
const regs = @import("../usbhs/regs.zig");
pub const dcp = @import("dcp.zig");
pub const host = @import("host.zig");
pub const pipe = @import("pipe.zig");
pub const bulk = @import("bulk.zig");

pub const window = struct {
    pub const base: u32 = 0x4025_0000;
    pub const span: u32 = 0x200;
    pub const word: u32 = 2;
    pub const words: u32 = span / word;
};

/// INTSTS0: the bits a device driver polls and clears.
pub const intsts0 = struct {
    pub const vbint: u16 = 1 << 15;
    pub const resm: u16 = 1 << 14;
    pub const sofr: u16 = 1 << 13;
    pub const dvst: u16 = 1 << 12;
    pub const ctrt: u16 = 1 << 11;
    pub const vbsts: u16 = 1 << 7;
    pub const valid: u16 = 1 << 3;
    /// DVSQ[2:0]: the device state the controller tracks on its own.
    pub const dvsq_mask: u16 = 0x0070;
    pub const dvsq_powered: u16 = 0x0000;
    pub const dvsq_default: u16 = 0x0010;
    pub const dvsq_address: u16 = 0x0020;
    pub const dvsq_configured: u16 = 0x0030;
    /// Status flags the driver clears by writing 0; a 1 leaves them alone.
    /// CTSQ[2:0]: the control-transfer stage the controller is in.
    pub const ctsq_mask: u16 = 0x0007;
    pub const ctsq_idle: u16 = 0b000;
    pub const ctsq_read_data: u16 = 0b001;
    pub const ctsq_read_status: u16 = 0b010;
    pub const ctsq_write_data: u16 = 0b011;
    pub const ctsq_write_status: u16 = 0b100;
    pub const ctsq_no_data_status: u16 = 0b101;
    pub const write_zero_clears: u16 = vbint | resm | sofr | dvst | ctrt | valid;
};

/// The standard requests the SIE acts on by itself, and what it keeps of them.
pub const request = struct {
    pub const set_address: u8 = 0x05;
    pub const set_configuration: u8 = 0x09;
    pub const address_mask: u8 = 0x7F;

    /// A standard host-to-device request addressed to the device itself.
    pub fn standardOut(packet: [8]u8, code: u8) bool {
        return packet[0] == 0x00 and packet[1] == code;
    }
};

pub const Device = struct {
    base: u32 = window.base,
    /// VBUS on the device jack. A board fact: the self-loop apps cable the
    /// two jacks together, so the board says when it is there.
    vbus: bool = false,
    syscfg: u16 = 0,
    status: u16 = 0,
    shadow: [window.words]u16 = @splat(0),
    /// The control FIFO port, aimed at the DCP.
    control: dcp.Dcp = .{},
    /// PIPE1 through PIPE9.
    pipes: pipe.Pipes = .{},
    /// The CFIFO port aimed at one of those pipes.
    endpoints: bulk.Bulk = .{},

    /// Accesses refused, each for its own reason.
    misaligned: u32 = 0,
    read_only: u32 = 0,

    /// Power the jack, the way plugging a cable in would. VBINT latches the
    /// change for the driver to see.
    pub fn connectVbus(self: *Device) void {
        defer self.settle();
        if (!self.vbus) self.status |= intsts0.vbint;
        self.vbus = true;
    }

    /// A SETUP packet from the host on the other jack lands on the DCP:
    /// USBREQ, USBVAL, USBINDX and USBLENG take its four fields, VALID and
    /// CTRT latch, and CTSQ moves to the stage the request asks for.
    /// SET_ADDRESS never reaches the driver: the SIE answers it, loads
    /// USBADDR and moves to the Address state. SET_CONFIGURATION reaches the
    /// driver like any request, and the SIE tracks the state it implies.
    pub fn setup(self: *Device, packet: [8]u8) void {
        // A SETUP sets the DCP PID back to NAK, clearing any earlier STALL.
        self.shadow[regs.reg.dcpctr / window.word] &= ~regs.dcpctr.pid_mask;
        if (request.standardOut(packet, request.set_address)) return self.addressed(packet[2]);
        if (request.standardOut(packet, request.set_configuration)) self.configured(packet[2]);
        const field = std.mem.readInt;
        self.shadow[regs.reg.usbreq / window.word] = field(u16, packet[0..2], .little);
        self.shadow[regs.reg.usbval / window.word] = field(u16, packet[2..4], .little);
        self.shadow[regs.reg.usbindx / window.word] = field(u16, packet[4..6], .little);
        const length = field(u16, packet[6..8], .little);
        self.shadow[regs.reg.usbleng / window.word] = length;
        const stage = if (packet[0] & 0x80 != 0)
            intsts0.ctsq_read_data
        else if (length != 0)
            intsts0.ctsq_write_data
        else
            intsts0.ctsq_no_data_status;
        self.status = (self.status & ~intsts0.ctsq_mask) | stage | intsts0.valid | intsts0.ctrt;
    }

    /// The host's status-stage token after a data stage: the OUT handshake
    /// that ends a control read, or the IN that ends a control write. CTSQ
    /// moves to the matching status stage with CTRT latched, which is the
    /// edge a driver waits for before it sets CCPL. A transfer the driver
    /// already ended, or one with no data stage, is left alone.
    pub fn statusStage(self: *Device) void {
        const next = switch (self.status & intsts0.ctsq_mask) {
            intsts0.ctsq_read_data => intsts0.ctsq_read_status,
            intsts0.ctsq_write_data => intsts0.ctsq_write_status,
            else => return,
        };
        self.status = (self.status & ~intsts0.ctsq_mask) | next | intsts0.ctrt;
    }

    fn addressed(self: *Device, value: u8) void {
        const address = value & request.address_mask;
        self.shadow[regs.reg.usbaddr / window.word] = address;
        self.moveTo(if (address != 0) intsts0.dvsq_address else intsts0.dvsq_default);
    }

    /// Only an addressed device can be configured; configuration 0 drops
    /// back to Address.
    fn configured(self: *Device, value: u8) void {
        const state = self.status & intsts0.dvsq_mask;
        if (state != intsts0.dvsq_address and state != intsts0.dvsq_configured) return;
        self.moveTo(if (value != 0) intsts0.dvsq_configured else intsts0.dvsq_address);
    }

    /// DCPCTR: PID reads back, BSTS reads ready, and CCPL ends the control
    /// transfer's status stage, so CTSQ goes back to idle with CTRT latched.
    fn controlPipe(self: *Device, value: u16) void {
        const stored = value & ~(regs.dcpctr.ccpl | regs.dcpctr.bsts);
        self.shadow[regs.reg.dcpctr / window.word] = stored;
        if (value & regs.dcpctr.ccpl == 0) return;
        if (self.status & intsts0.ctsq_mask == intsts0.ctsq_idle) return;
        const rest = self.status & ~intsts0.ctsq_mask;
        self.status = rest | intsts0.ctsq_idle | intsts0.ctrt;
    }

    fn controlPipeStatus(self: *const Device) u16 {
        return self.shadow[regs.reg.dcpctr / window.word] | regs.dcpctr.bsts;
    }

    fn attached(self: *const Device) bool {
        return self.lineState() == regs.port.lnst_j and self.syscfg & regs.syscfg.usbe != 0;
    }

    /// The host on the other jack resets the bus as soon as it sees the
    /// pull-up, so an attach lands straight in the Default state at full
    /// speed with DVST latched. Dropping the pull-up goes back to Powered.
    /// Rewriting SYSCFG while attached keeps the state the host got it to.
    fn settle(self: *Device) void {
        if (!self.attached()) return self.moveTo(intsts0.dvsq_powered);
        if (self.status & intsts0.dvsq_mask == intsts0.dvsq_powered) self.moveTo(intsts0.dvsq_default);
    }

    /// DVSQ takes the new state and DVST latches the change.
    fn moveTo(self: *Device, want: u16) void {
        if (self.status & intsts0.dvsq_mask == want) return;
        self.status = (self.status & ~intsts0.dvsq_mask) | want | intsts0.dvst;
    }

    /// DVSTCTR0.RHST: full speed once the reset has put the device in a
    /// state past Powered. The rest of the register reads back from the
    /// shadow.
    pub fn portStatus(self: *const Device) u16 {
        const stored = self.shadow[regs.reg.dvstctr0 / window.word] & ~regs.port.rhst_mask;
        if (self.status & intsts0.dvsq_mask == intsts0.dvsq_powered) return stored;
        return stored | regs.port.rhst_full;
    }

    fn aligned(self: *Device, offset: u32) bool {
        if (offset % window.word == 0 and offset < window.span) return true;
        self.misaligned += 1;
        return false;
    }

    /// SYSSTS0.LNST: J-state once a device-role driver pulls D+ up with VBUS
    /// present, SE0 otherwise. Nothing drives K or a reset yet.
    pub fn lineState(self: *const Device) u16 {
        const device_role = self.syscfg & regs.syscfg.dcfm == 0;
        const pulled_up = self.syscfg & regs.syscfg.dprpu != 0;
        if (self.vbus and device_role and pulled_up) return regs.port.lnst_j;
        return 0;
    }

    /// USBFS_INT: some INTSTS0 status bit in 15:8 is set with its INTENB0
    /// enable. VALID raises nothing on its own; the SETUP stage reaches the
    /// line through CTRT.
    pub fn interruptLine(self: *const Device) bool {
        const enabled = self.shadow[regs.reg.intenb0 / window.word];
        return self.interruptStatus() & enabled & 0xFF00 != 0;
    }

    pub fn interruptStatus(self: *const Device) u16 {
        const live: u16 = if (self.vbus) intsts0.vbsts else 0;
        return (self.status & ~intsts0.vbsts) | live | self.control.summary() | self.endpoints.summary();
    }

    pub fn read(self: *Device, address: u32, width: u3) u32 {
        const offset = address -% self.base;
        if (!self.aligned(offset)) return 0;
        if (pipe.Pipes.owns(offset)) return self.pipes.read(offset);
        return switch (offset) {
            regs.reg.syscfg => self.syscfg,
            regs.reg.syssts0 => self.lineState(),
            regs.reg.intsts0 => self.interruptStatus(),
            regs.reg.dvstctr0 => self.portStatus(),
            regs.reg.dcpctr => self.controlPipeStatus(),
            regs.reg.cfifo => if (self.bulkPipe()) |n| self.endpoints.readData(&self.pipes, n, width) else self.control.readData(width),
            regs.reg.cfifosel => self.control.sel,
            regs.reg.cfifoctr => if (self.bulkPipe()) |n| self.endpoints.status(&self.pipes, n) else self.control.status(),
            regs.reg.brdysts => @intFromBool(self.control.brdy) | self.endpoints.brdy,
            regs.reg.bempsts => @intFromBool(self.control.bemp) | self.endpoints.bemp,
            else => self.shadow[offset / window.word],
        };
    }

    pub fn write(self: *Device, address: u32, width: u3, value: u32) void {
        const offset = address -% self.base;
        if (!self.aligned(offset)) return;
        const v: u16 = @truncate(value);
        if (pipe.Pipes.owns(offset)) return self.pipes.write(offset, v);
        switch (offset) {
            regs.reg.syscfg => {
                self.syscfg = v;
                self.settle();
            },
            regs.reg.syssts0 => self.read_only += 1,
            regs.reg.usbreq, regs.reg.usbval, regs.reg.usbindx, regs.reg.usbleng => self.read_only += 1,
            regs.reg.intsts0 => self.status &= v | ~intsts0.write_zero_clears,
            regs.reg.dcpctr => self.controlPipe(v),
            regs.reg.cfifo => if (self.bulkPipe()) |n| self.endpoints.writeData(&self.pipes, n, value, width) else self.control.writeData(value, width),
            regs.reg.cfifosel => self.selectPort(v),
            regs.reg.cfifoctr => if (self.bulkPipe()) |n| self.endpoints.control(&self.pipes, n, v) else self.control.control(v),
            regs.reg.brdysts => {
                self.control.brdy = self.control.brdy and v & 1 != 0;
                self.endpoints.brdy &= v;
            },
            regs.reg.bempsts => {
                self.control.bemp = self.control.bemp and v & 1 != 0;
                self.endpoints.bemp &= v;
            },
            else => self.shadow[offset / window.word] = v,
        }
    }

    pub fn refusals(self: *const Device) u32 {
        const port = self.control.refusals() + self.endpoints.refusals();
        return self.misaligned + self.read_only + port + self.pipes.unselected;
    }

    /// CFIFOSEL.CURPIPE when it names a pipe the driver opened. The port
    /// then belongs to that pipe; otherwise it is the DCP's.
    fn bulkPipe(self: *const Device) ?u4 {
        const n: u4 = @truncate(self.control.sel & regs.fifo.curpipe_mask);
        _ = bulk.opened(&self.pipes, n) orelse return null;
        return n;
    }

    /// CFIFOSEL: aiming at an opened pipe is not a DCP refusal.
    fn selectPort(self: *Device, value: u16) void {
        const n: u4 = @truncate(value & regs.fifo.curpipe_mask);
        if (bulk.opened(&self.pipes, n) != null) {
            self.control.sel = value;
        } else self.control.select(value);
    }

    pub fn block(self: *Device) periph.Block {
        return .{
            .name = "USBFS-device",
            .base = self.base,
            .size = window.span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Device = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Device = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
