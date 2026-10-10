//! The Ethernet part of the end-of-run report: how far each R-Switch port
//! got through its mode machine, and what the MDIO bus was asked.
//!
//! The refused mode step is the loud case. dev reads the mode status straight
//! out of the mode command, so an image that skipped a rung comes up
//! operational in the emulator and hangs against the real state machine. A
//! frame aimed at a PHY the board does not have, and a write to a register
//! the PHY measures itself, are the other two.
const Board = @import("ra8_board").board.Board;
const Writer = @import("../report.zig").Writer;
const eth_phy = @import("ra8_components").eth_phy;
const eth_mac = @import("ra8_chip").periph.eth_mac;
const eth = @import("ra8_chip").periph.eth;
const net = @import("ra8_board").net;
const pdctr = @import("ra8_chip").periph.pdctr;

pub fn sections(board: *Board, out: Writer) !void {
    try domain(board, out);
    const cluster = &board.rswitch;
    if (cluster.quiet()) return;
    for (&cluster.ports, 0..) |*port, index| {
        if (port.quiet() and cluster.phys[index].quiet()) continue;
        try out.print(
            "ETHA{d}: mode {s}, {d} command(s), {d} change(s)",
            .{ index, @tagName(port.mode.mode), port.mode.commands, port.mode.changes },
        );
        try refusedSteps(&port.mode, out);
        try out.print("\n", .{});
        try unpowered(index, port, out);
        try macAddress(index, &port.mac, out);
        try mdio(index, &cluster.phys[index], out);
    }
    try gateway(cluster, out);
    try rings(cluster, out);
}

/// The descriptor side: what actually moved through the rings, and every
/// frame the engine would not move.
fn rings(cluster: *const net.Rswitch, out: Writer) !void {
    const window = &cluster.queues;
    if (window.quiet()) return;
    const dma = &window.rings;
    try out.print(
        "GWCA rings: {d} TX kick(s), {d} frame(s) out, {d} frame(s) in",
        .{ dma.kicks, dma.tx_frames, dma.rx_frames },
    );
    try refusedFrames(&dma.refused, out);
    if (window.base_late != 0) try out.print(
        ", {d} RING BASE WRITE(S) OFF A GATEWAY IN CONFIG REFUSED",
        .{window.base_late},
    );
    try out.print("\n", .{});
}

fn refusedFrames(refused: anytype, out: Writer) !void {
    if (refused.stopped != 0) try out.print(
        ", {d} KICK(S) ON A GATEWAY NOT IN OPERATION REFUSED",
        .{refused.stopped},
    );
    if (refused.off_ram != 0) try out.print(
        ", {d} DESCRIPTOR(S) POINTING SOMEWHERE THE GATEWAY CANNOT REACH REFUSED",
        .{refused.off_ram},
    );
    if (refused.too_big != 0) try out.print(
        ", {d} FRAME(S) TOO BIG FOR THE SLOT LEFT QUEUED",
        .{refused.too_big},
    );
    if (refused.blocked != 0) try out.print(
        ", {d} FRAME(S) THE FAR END HAD NO ROOM FOR",
        .{refused.blocked},
    );
    if (refused.looped != 0) try out.print(", {d} RING(S) THAT LINK BACK ON THEMSELVES", .{refused.looped});
    if (refused.runt != 0) try out.print(", {d} DESCRIPTOR(S) TOO SHORT TO BE A FRAME", .{refused.runt});
    if (refused.oversize != 0) try out.print(", {d} DESCRIPTOR(S) OVER THE FRAME LIMIT", .{refused.oversize});
    if (refused.fragment != 0) try out.print(", {d} MULTI-FRAGMENT HEAD(S) LEFT ALONE", .{refused.fragment});
    if (refused.ring_full != 0) try out.print(", {d} FULL RING(S)", .{refused.ring_full});
}

fn refusedSteps(machine: anytype, out: Writer) !void {
    if (machine.refused == 0) return;
    try out.print(
        ", {d} MODE STEP(S) REFUSED (last asked for {s})",
        .{ machine.refused, @tagName(machine.last_refused.?) },
    );
}

/// The perfect-match address the port ended up carrying. A store made while
/// the port was not in CONFIG never reached the register on silicon, so the
/// count is the one that says why a wire-side ARP would go unanswered.
fn macAddress(index: usize, part: *const eth_mac.Address, out: Writer) !void {
    if (part.quiet()) return;
    const octets = part.octets();
    try out.print(
        "RMAC{d} address: {x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}, {d} store(s)",
        .{ index, octets[0], octets[1], octets[2], octets[3], octets[4], octets[5], part.stores },
    );
    if (part.ignored != 0) try out.print(
        ", {d} ADDRESS STORE(S) OFF A PORT NOT IN CONFIG REFUSED",
        .{part.ignored},
    );
    try out.print("\n", .{});
}

fn mdio(index: usize, part: *const eth_phy.Phy, out: Writer) !void {
    if (part.quiet()) return;
    try out.print(
        "RMAC{d} MDIO: {d} read(s), {d} write(s), {d} PHY reset(s)",
        .{ index, part.reads, part.writes, part.resets },
    );
    if (part.no_phy != 0) try out.print(
        ", {d} FRAME(S) ADDRESSED TO A PHY THIS BOARD DOES NOT HAVE",
        .{part.no_phy},
    );
    if (part.read_only != 0) try out.print(
        ", {d} WRITE(S) TO A REGISTER THE PHY MEASURES REFUSED",
        .{part.read_only},
    );
    if (part.unsupported != 0) try out.print(
        ", {d} CLAUSE-45 FRAME(S) REFUSED",
        .{part.unsupported},
    );
    if (part.bad_op != 0) try out.print(
        ", {d} FRAME(S) WITH NO CLAUSE-22 OPERATION REFUSED",
        .{part.bad_op},
    );
    try out.print("\n", .{});
}

fn gateway(cluster: *const net.Rswitch, out: Writer) !void {
    const agent = &cluster.gateway;
    if (agent.quiet() and cluster.pool.quiet()) return;
    try out.print(
        "GWCA: mode {s}, {d} command(s), {d} AXI init(s), {d} buffer-pool init(s)",
        .{ @tagName(agent.mode.mode), agent.mode.commands, agent.inits, cluster.pool.inits },
    );
    try refusedSteps(&agent.mode, out);
    try out.print("\n", .{});
}

/// PDCTRESWM, the Ethernet switch power domain. Gated at reset, so a driver
/// that never clears PDDE reads every per-port window back as zero and sees
/// its own stores vanish with no fault raised anywhere.
fn domain(board: *Board, out: Writer) !void {
    const unit = &board.domains.eswm;
    if (unit.quiet()) return;
    try out.print(
        "PWR-ESWM: domain {s}, {d} power-on(s), {d} power-off(s)\n",
        .{ if (unit.powered()) "powered" else "GATED", unit.power_ons, unit.power_offs },
    );
    if (unit.dropped_locked == 0) return;
    try out.print(
        "PWR-ESWM: DROPPED {d} write(s) with PRCR.PRC1 locked (unlock with 0xA502)\n",
        .{unit.dropped_locked},
    );
}

/// What the gate swallowed on one port. Separate from the mode line because
/// the mode line reports what the port reached, and this reports the accesses
/// that never reached it at all.
fn unpowered(index: usize, port: *const eth.Port, out: Writer) !void {
    if (port.dropped_unpowered == 0 and port.dark_reads == 0) return;
    try out.print(
        "ETHA{d}: DROPPED {d} write(s) and read {d} window(s) back as zero, ESWM domain gated off (clear PDCTRESWM.PDDE first)\n",
        .{ index, port.dropped_unpowered, port.dark_reads },
    );
}
