//! The `ethernet` object of `--report json` (RA8EMU-364): the ESWM power
//! domain, each R-Switch port with its MAC address and MDIO bus, the GWCA
//! gateway and its descriptor rings, the same facts report/ether.zig
//! prints. Every key is always present; `ports` holds only the ports the
//! firmware touched.
const std = @import("std");
const Board = @import("ra8_board").board.Board;
const net = @import("ra8_board").net;

/// The whole `ethernet` object, keyed inside the document.
pub fn section(j: anytype, board: *Board) !void {
    const cluster = &board.rswitch;
    const domain = &board.domains.eswm;
    try j.open("ethernet", '{');
    try j.open("eswm", '{');
    try j.field("powered", domain.powered());
    try j.field("power_ons", domain.power_ons);
    try j.field("power_offs", domain.power_offs);
    try j.field("dropped_locked", domain.dropped_locked);
    try j.close('}');
    try ports(j, cluster);
    try j.open("gateway", '{');
    try j.field("mode", @tagName(cluster.gateway.mode.mode));
    try j.field("commands", cluster.gateway.mode.commands);
    try j.field("axi_inits", cluster.gateway.inits);
    try j.field("pool_inits", cluster.pool.inits);
    try steps(j, &cluster.gateway.mode);
    try j.close('}');
    try rings(j, cluster);
    try j.close('}');
}

fn steps(j: anytype, machine: anytype) !void {
    try j.field("refused_steps", machine.refused);
    try j.field("last_refused", if (machine.refused != 0) if (machine.last_refused) |m| @tagName(m) else null else null);
}

fn ports(j: anytype, cluster: *const net.Rswitch) !void {
    try j.open("ports", '[');
    for (&cluster.ports, 0..) |*port, index| {
        if (port.quiet() and cluster.phys[index].quiet()) continue;
        try j.open(null, '{');
        try j.field("index", index);
        try j.field("mode", @tagName(port.mode.mode));
        try j.field("commands", port.mode.commands);
        try j.field("changes", port.mode.changes);
        try steps(j, &port.mode);
        try j.field("dropped_unpowered", port.dropped_unpowered);
        try j.field("dark_reads", port.dark_reads);
        const octets = port.mac.octets();
        var text: [17]u8 = undefined;
        _ = try std.fmt.bufPrint(&text, "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{ octets[0], octets[1], octets[2], octets[3], octets[4], octets[5] });
        try j.open("mac", '{');
        try j.field("address", if (port.mac.quiet()) null else @as([]const u8, &text));
        try j.field("stores", port.mac.stores);
        try j.field("refused_not_config", port.mac.ignored);
        try j.close('}');
        const phy = &cluster.phys[index];
        try j.open("mdio", '{');
        try j.field("reads", phy.reads);
        try j.field("writes", phy.writes);
        try j.field("phy_resets", phy.resets);
        try j.field("no_phy", phy.no_phy);
        try j.field("refused_read_only", phy.read_only);
        try j.field("refused_clause45", phy.unsupported);
        try j.field("refused_bad_op", phy.bad_op);
        try j.close('}');
        try j.close('}');
    }
    try j.close(']');
}

fn rings(j: anytype, cluster: *const net.Rswitch) !void {
    const window = &cluster.queues;
    const dma = &window.rings;
    const refused = &dma.refused;
    try j.open("rings", '{');
    try j.field("tx_kicks", dma.kicks);
    try j.field("tx_frames", dma.tx_frames);
    try j.field("rx_frames", dma.rx_frames);
    try j.field("refused_base_late", window.base_late);
    try j.open("refused", '{');
    try j.field("gateway_stopped", refused.stopped);
    try j.field("off_ram", refused.off_ram);
    try j.field("too_big", refused.too_big);
    try j.field("far_end_full", refused.blocked);
    try j.field("looped", refused.looped);
    try j.field("runt", refused.runt);
    try j.field("oversize", refused.oversize);
    try j.field("fragment", refused.fragment);
    try j.field("ring_full", refused.ring_full);
    try j.close('}');
    try j.close('}');
}
