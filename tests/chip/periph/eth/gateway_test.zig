//! GWCA and COMA: the two handshakes the bring-up polls, and the mode
//! machine the gateway is held to.
const std = @import("std");
const ra8 = @import("ra8");
const regs = ra8.chip.periph.eth.regs;
const gateway = ra8.chip.periph.eth.gateway;

test "GWMS reports the gateway's mode" {
    var agent = gateway.Gateway{};
    for ([_]u32{ 2, 1, 3 }) |code| agent.modeWrite(regs.cluster.gwca0 + regs.gwca.gwmc, 4, code);
    try std.testing.expectEqual(@as(u32, 3), agent.modeRead(regs.cluster.gwca0 + regs.gwca.gwms, 4));
    try std.testing.expect(agent.mode.operational());
}

test "a gateway in reset refuses a direct operation request" {
    var agent = gateway.Gateway{};
    agent.mode.mode = .reset;
    agent.modeWrite(regs.cluster.gwca0 + regs.gwca.gwmc, 4, 3);
    try std.testing.expectEqual(@as(u32, 0), agent.modeRead(regs.cluster.gwca0 + regs.gwca.gwms, 4));
    try std.testing.expectEqual(@as(u32, 1), agent.mode.refused);
}

test "GWMS is the machine's to report" {
    var agent = gateway.Gateway{};
    agent.modeWrite(regs.cluster.gwca0 + regs.gwca.gwms, 4, 3);
    try std.testing.expectEqual(@as(u32, 0), agent.mode.commands);
}

test "the AXI init answers the request it was given" {
    var agent = gateway.Gateway{};
    const at = regs.cluster.gwca0 + regs.gwca.gwarirm;
    try std.testing.expectEqual(@as(u32, 0), agent.arirmRead(at, 4) & regs.gwca.arr);
    var fwpc = [_]u32{ 1, 1, 1 };
    agent.fwpc = &fwpc;
    agent.arirmWrite(at, 4, regs.gwca.ariog);
    try std.testing.expect(agent.arirmRead(at, 4) & regs.gwca.arr != 0);
    try std.testing.expectEqual(@as(u32, 1), agent.inits);
}

test "the AXI init waits until each agent enables extended descriptors" {
    var agent = gateway.Gateway{};
    var fwpc = [_]u32{ 1, 0, 1 };
    agent.fwpc = &fwpc;
    const at = regs.cluster.gwca0 + regs.gwca.gwarirm;
    agent.arirmWrite(at, 4, regs.gwca.ariog);
    try std.testing.expectEqual(@as(u32, 0), agent.arirmRead(at, 4) & regs.gwca.arr);
    fwpc[1] = 1;
    try std.testing.expect(agent.arirmRead(at, 4) & regs.gwca.arr != 0);
}

test "holding ARIOG does not count a second init" {
    var agent = gateway.Gateway{};
    var fwpc = [_]u32{ 1, 1, 1 };
    agent.fwpc = &fwpc;
    const at = regs.cluster.gwca0 + regs.gwca.gwarirm;
    agent.arirmWrite(at, 4, regs.gwca.ariog);
    agent.arirmWrite(at, 4, regs.gwca.ariog);
    try std.testing.expectEqual(@as(u32, 1), agent.inits);
}

test "the buffer pool answers its own request" {
    var pool = gateway.Pool{};
    const at = regs.cluster.coma + regs.coma.cabpirm;
    try std.testing.expectEqual(@as(u32, 0), pool.read(at, 4));
    pool.write(at, 4, regs.coma.bpiog);
    try std.testing.expect(pool.read(at, 4) & regs.coma.bpr != 0);
    try std.testing.expectEqual(@as(u32, 1), pool.inits);
}

test "a pool that was never asked reports no init done" {
    var pool = gateway.Pool{};
    const at = regs.cluster.coma + regs.coma.cabpirm;
    pool.write(at, 4, 0);
    try std.testing.expectEqual(@as(u32, 0), pool.read(at, 4) & regs.coma.bpr);
    try std.testing.expect(pool.quiet());
}

test "an agent nothing touched is quiet" {
    const agent = gateway.Gateway{};
    try std.testing.expect(agent.quiet());
}

test "a store above OPC is not a gateway mode command" {
    var agent = gateway.Gateway{};
    agent.modeWrite(regs.cluster.gwca0 + regs.gwca.gwmc + 2, 2, 0xFFFF);
    try std.testing.expectEqual(@as(u32, 0), agent.mode.commands);
}

test "a byte store at GWMC commands the gateway" {
    var agent = gateway.Gateway{};
    agent.modeWrite(regs.cluster.gwca0 + regs.gwca.gwmc, 1, 1);
    try std.testing.expectEqual(@as(u32, 1), agent.modeRead(regs.cluster.gwca0 + regs.gwca.gwms, 1));
}

test "a byte store at GWARIRM still asks for the AXI init" {
    var agent = gateway.Gateway{};
    const at = regs.cluster.gwca0 + regs.gwca.gwarirm;
    agent.arirmWrite(at, 1, regs.gwca.ariog);
    try std.testing.expectEqual(@as(u32, 1), agent.inits);
    var fwpc = [_]u32{ 1, 1, 1 };
    agent.fwpc = &fwpc;
    try std.testing.expect(agent.arirmRead(at, 1) & regs.gwca.arr != 0);
}

test "a store above ARIOG keeps the request bit where it was" {
    var agent = gateway.Gateway{};
    const at = regs.cluster.gwca0 + regs.gwca.gwarirm;
    agent.arirmWrite(at, 4, regs.gwca.ariog);
    agent.arirmWrite(at + 2, 2, 0x1234);
    try std.testing.expectEqual(@as(u32, 1), agent.inits);
    try std.testing.expect(agent.arirm & regs.gwca.ariog != 0);
}

test "a byte store at CABPIRM still asks for the pool init" {
    var pool = gateway.Pool{};
    const at = regs.cluster.coma + regs.coma.cabpirm;
    pool.write(at, 1, regs.coma.bpiog);
    try std.testing.expectEqual(@as(u32, 1), pool.inits);
    try std.testing.expect(pool.read(at, 1) & regs.coma.bpr != 0);
}
