//! The board's Ethernet side: the R-Switch cluster as this board populates
//! it, two ports and the two shared agents.
//!
//! Which ports exist and where their PHYs answer is a board fact, so the
//! wiring lives here rather than in the port model: the PHYs and the far end
//! of the wire are board parts (src/components/eth_phy) this connects.
const Guest = @import("ra8_chip").core.cpu.memory.guest.Guest;
const eth = @import("ra8_chip").periph.eth;
const eth_queue = @import("ra8_chip").periph.eth.queue;
const eth_phy = @import("ra8_components").eth_phy;
const eth_peer = @import("ra8_components").eth_peer;
const gateway = @import("ra8_chip").periph.eth.gateway;
const pdctr = @import("ra8_chip").periph.pdctr;
const periph = @import("ra8_chip").periph.registry;
const regs = @import("ra8_chip").periph.eth.regs;

pub const Rswitch = struct {
    ports: [regs.cluster.port_count]eth.Port = .{
        eth.Port.init(regs.cluster.etha0, regs.cluster.rmac0),
        eth.Port.init(regs.cluster.etha1, regs.cluster.rmac1),
    },
    /// Each port's PHY, on that port's MDIO bus.
    phys: [regs.cluster.port_count]eth_phy.Phy = @splat(eth_phy.Phy.init()),
    /// The far end of the wire the gateway's DMA sends on and takes from.
    peer: eth_peer.Link = .{},
    /// Each port's queue depth and error-interrupt words.
    agents: [regs.cluster.port_count]eth.agent.Agent = .{
        eth.agent.Agent.init(regs.cluster.etha0),
        eth.agent.Agent.init(regs.cluster.etha1),
    },
    /// The forwarding engine's control and per-port words.
    forward: eth.forward.Forward = .{},
    /// Setup-only Ethernet words outside the behavioral block models.
    open_regs: eth.open_regs.Bank = .{},
    /// COMA's reset and clock-enable words.
    coma: eth.coma.Coma = .{},
    gateway: gateway.Gateway = .{},
    pool: gateway.Pool = .{},
    /// The gateway's descriptor side: the rings in RAM and the frames that
    /// move through them.
    queues: eth_queue.Queues = .{},

    /// Put every window the cluster answers for on the bus. The blocks hold
    /// pointers into this struct, so this runs once the board has stopped
    /// moving, and the ESWM power domain is wired to each port here for the
    /// same reason.
    pub fn attach(
        self: *Rswitch,
        bus: *periph.Bus,
        memory: Guest,
        domain: *const pdctr.Pdctr,
    ) periph.Error!void {
        for (&self.ports, &self.phys) |*port, *phy| {
            port.mdio = phy.mdio();
            // The whole cluster sits in the ESWM power domain, so every port
            // asks the same one before it answers.
            port.domain = domain;
            try bus.add(port.ethaBlock());
            try bus.add(port.cbsBlock());
            try bus.add(port.tasBlock());
            try bus.add(port.rmacBlock());
            try bus.add(port.macBlock());
        }
        for (&self.agents) |*agent| {
            for (agent.blocks()) |block| try bus.add(block);
        }
        for (self.forward.blocks()) |block| try bus.add(block);
        for (self.open_regs.blocks()) |block| try bus.add(block);
        try bus.add(self.coma.block());
        try bus.add(self.gateway.modeBlock());
        try bus.add(self.gateway.arirmBlock());
        try bus.add(self.pool.block());
        self.gateway.fwpc = &self.forward.fwpc;
        self.queues.mode = &self.gateway.mode;
        self.queues.rings.memory = memory;
        self.queues.rings.link = self.peer.wire();
        try bus.add(self.queues.baseBlock());
        try bus.add(self.queues.requestBlock());
        try bus.add(self.queues.configBlock());
    }

    /// The chunk boundary: the rings take in whatever the far end has for
    /// them, once the gateway is running.
    pub fn tick(self: *Rswitch) void {
        self.queues.tick();
    }

    pub fn quiet(self: *const Rswitch) bool {
        for (&self.ports) |*port| {
            if (!port.quiet()) return false;
        }
        for (&self.phys) |*phy| {
            if (!phy.quiet()) return false;
        }
        for (&self.agents) |*agent| {
            if (!agent.quiet()) return false;
        }
        if (!self.coma.quiet()) return false;
        return self.forward.quiet() and self.open_regs.quiet() and
            (self.gateway.quiet() and self.pool.quiet() and self.queues.quiet());
    }
};
