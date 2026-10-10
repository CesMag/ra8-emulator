//! The CPU agent's descriptor-control window: where the rings are, which
//! queue is a reception queue, and the request that kicks one.
//!
//! Three small windows into the same gateway, so they sit in one file with
//! the engine they drive: GWDCBAC (the chain base), GWTRC (the TX request),
//! and GWDCC (the per-queue descriptor configuration).
//!
//! Two things dev does not do. THE RING BASE IS TAKEN IN CONFIG: dev captures
//! GWDCBAC1 whenever it is written, so an image that re-points the chain base
//! on a running gateway moved the rings under a live DMA and the emulator
//! followed it. The register still reads back what was written here, because
//! a register does, but the engine only takes the base in CONFIG mode, which
//! is where the gateway declares it writable. AND A QUEUE STOPS RECEIVING
//! WHEN IT IS RECONFIGURED: dev records a reception queue on a GWDCC write
//! with DQT clear and never unrecords one, so a queue turned into a transmit
//! queue is still drained into.
//!
//! Every register in the three windows is 32 bits, so an access narrower than
//! a word takes the `lanes.zig` rule: a read is cut to the lanes it names, a
//! store keeps the lanes it does not.
const std = @import("std");
const lanes = @import("../lanes.zig");
const periph = @import("../registry.zig");
const regs = @import("regs.zig");
const eth_mode = @import("mode.zig");
const eth_dma = @import("dma.zig");

pub const Queues = struct {
    base: u32 = regs.cluster.gwca0,
    /// The gateway's own mode machine. The rings run in OPERATION and the
    /// base is taken in CONFIG, so this window has to be able to ask. A test
    /// that does not set it gets a gateway that is never running.
    mode: ?*const eth_mode.Machine = null,
    rings: eth_dma.Dma = .{},
    /// GWDCC[i] as written, for the read back.
    config: [regs.gwca.queue_count]u32 = @splat(0),
    chain_base: [2]u32 = .{ 0, 0 },
    /// Ring-base writes the gateway was not in CONFIG for.
    base_late: u32 = 0,

    pub fn tick(self: *Queues) void {
        self.rings.tick(self.operational());
    }

    pub fn quiet(self: *const Queues) bool {
        return self.rings.quiet() and self.base_late == 0;
    }

    pub fn baseRead(self: *Queues, address: u32, width: u3) u32 {
        const offset = address -% self.base;
        const whole: u32 = switch (lanes.word(offset)) {
            regs.gwca.gwdcbac0 => self.chain_base[0],
            regs.gwca.gwdcbac1 => self.chain_base[1],
            else => 0,
        };
        return lanes.part(whole, lanes.lane(offset), width);
    }

    /// A ring base is an address, and a driver is entitled to lay one down in
    /// two halfword stores. The engine takes the whole register afterwards,
    /// not the half that happened to arrive last.
    pub fn baseWrite(self: *Queues, address: u32, width: u3, value: u32) void {
        const offset = address -% self.base;
        const at = lanes.lane(offset);
        switch (lanes.word(offset)) {
            // The upper half of a 64-bit AXI address. Nothing in this part's
            // map lives above four gigabytes, so it is remembered and unused.
            regs.gwca.gwdcbac0 => {
                self.chain_base[0] = lanes.merge(self.chain_base[0], at, width, value);
            },
            regs.gwca.gwdcbac1 => {
                self.chain_base[1] = lanes.merge(self.chain_base[1], at, width, value);
                if (self.configuring()) {
                    self.rings.linkfix = self.chain_base[1];
                } else {
                    self.base_late += 1;
                }
            },
            else => {},
        }
    }

    /// The request register reads back zero: it is consumed when written.
    pub fn requestRead(self: *Queues, address: u32, width: u3) u32 {
        _ = self;
        _ = address;
        _ = width;
        return 0;
    }

    /// One bit per queue, so which lanes a store names is which queues it
    /// kicks: a halfword at the top of GWTRC0 asks for queues 16 to 31, not
    /// for the sixteen at the bottom of the word.
    pub fn requestWrite(self: *Queues, address: u32, width: u3, value: u32) void {
        const offset = address -% self.base;
        const register = lanes.word(offset);
        if (register != regs.gwca.gwtrc0 and register != regs.gwca.gwtrc1) return;
        const first: u32 = if (register == regs.gwca.gwtrc1) regs.gwca.request_bits else 0;
        // The register is consumed when written, so there is nothing under a
        // narrow store to keep: the bits it carries just land in their lanes.
        const asked = lanes.merge(0, lanes.lane(offset), width, value);
        self.rings.kick(asked, first, self.operational());
    }

    /// GWDCC.BALR is the reload request, and it is finished by the time the
    /// driver reads the register back.
    pub fn configRead(self: *Queues, address: u32, width: u3) u32 {
        const queue = self.queueOf(address) orelse return 0;
        const whole = self.config[queue] & ~regs.gwca.balr;
        return lanes.part(whole, lanes.lane(address), width);
    }

    /// DQT decides which way a queue runs, and it is the register that says
    /// so, not the store: a narrow write that never reaches DQT's lane leaves
    /// the direction where the configuration already had it.
    pub fn configWrite(self: *Queues, address: u32, width: u3, value: u32) void {
        const queue = self.queueOf(address) orelse return;
        const asked = lanes.merge(self.config[queue], lanes.lane(address), width, value);
        self.config[queue] = asked;
        const mask = @as(u64, 1) << @as(u6, @intCast(queue));
        if (asked & regs.gwca.dqt == 0) {
            self.rings.receiving |= mask;
        } else {
            self.rings.receiving &= ~mask;
        }
    }

    pub fn baseBlock(self: *Queues) periph.Block {
        return .{
            .name = "GWDCBAC",
            .base = self.base + regs.gwca.gwdcbac0,
            .size = regs.gwca.base_span,
            .context = self,
            .readFn = baseReadThunk,
            .writeFn = baseWriteThunk,
        };
    }

    pub fn requestBlock(self: *Queues) periph.Block {
        return .{
            .name = "GWTRC",
            .base = self.base + regs.gwca.gwtrc0,
            .size = regs.gwca.request_span,
            .context = self,
            .readFn = requestReadThunk,
            .writeFn = requestWriteThunk,
        };
    }

    pub fn configBlock(self: *Queues) periph.Block {
        return .{
            .name = "GWDCC",
            .base = self.base + regs.gwca.gwdcc,
            .size = regs.gwca.config_span,
            .context = self,
            .readFn = configReadThunk,
            .writeFn = configWriteThunk,
        };
    }

    fn queueOf(self: *const Queues, address: u32) ?usize {
        const offset = address -% (self.base + regs.gwca.gwdcc);
        const queue = offset / 4;
        if (queue >= regs.gwca.queue_count) return null;
        return @intCast(queue);
    }

    fn operational(self: *const Queues) bool {
        const machine = self.mode orelse return false;
        return machine.operational();
    }

    fn configuring(self: *const Queues) bool {
        const machine = self.mode orelse return false;
        return machine.mode == .config;
    }
};

fn baseReadThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Queues = @ptrCast(@alignCast(context));
    return self.baseRead(address, width);
}

fn baseWriteThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Queues = @ptrCast(@alignCast(context));
    self.baseWrite(address, width, value);
}

fn requestReadThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Queues = @ptrCast(@alignCast(context));
    return self.requestRead(address, width);
}

fn requestWriteThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Queues = @ptrCast(@alignCast(context));
    self.requestWrite(address, width, value);
}

fn configReadThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Queues = @ptrCast(@alignCast(context));
    return self.configRead(address, width);
}

fn configWriteThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Queues = @ptrCast(@alignCast(context));
    self.configWrite(address, width, value);
}
