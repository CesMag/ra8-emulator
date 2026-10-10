//! The R-Switch mode machine: reset state and silicon-supported transitions.
const std = @import("std");
const ra8 = @import("ra8");
const eth_mode = ra8.chip.periph.eth.mode;

test "the machine starts in the reset default disable mode" {
    const machine = eth_mode.Machine{};
    try std.testing.expectEqual(eth_mode.Mode.disable, machine.mode);
    try std.testing.expect(machine.quiet());
}

test "a reset-mode request returns the agent to disable" {
    var machine = eth_mode.Machine{};
    machine.command(@backingInt(eth_mode.Mode.reset));
    try std.testing.expectEqual(eth_mode.Mode.reset, machine.mode);
    machine.command(@backingInt(eth_mode.Mode.disable));
    try std.testing.expectEqual(eth_mode.Mode.disable, machine.mode);
    try std.testing.expectEqual(@as(u32, 0), machine.refused);
}

test "the firmware mode path reaches operation without refused commands" {
    var machine = eth_mode.Machine{};
    for ([_]eth_mode.Mode{ .operation, .disable, .config, .disable, .operation }) |mode| {
        machine.command(@backingInt(mode));
    }
    try std.testing.expectEqual(eth_mode.Mode.operation, machine.mode);
    try std.testing.expectEqual(@as(u32, 0), machine.refused);
}

test "the mode graph permits driver paths and rejects skipped states" {
    try std.testing.expect(eth_mode.reachable(.reset, .disable));
    try std.testing.expect(eth_mode.reachable(.disable, .reset));
    try std.testing.expect(eth_mode.reachable(.disable, .config));
    try std.testing.expect(eth_mode.reachable(.config, .disable));
    try std.testing.expect(eth_mode.reachable(.disable, .operation));
    try std.testing.expect(eth_mode.reachable(.operation, .disable));
    try std.testing.expect(!eth_mode.reachable(.reset, .config));
    try std.testing.expect(!eth_mode.reachable(.reset, .operation));
    try std.testing.expect(eth_mode.reachable(.config, .operation));
    try std.testing.expect(eth_mode.reachable(.operation, .config));
    try std.testing.expect(!eth_mode.reachable(.operation, .reset));
}

test "a refused request leaves status at the actual mode" {
    var machine = eth_mode.Machine{ .mode = .reset };
    machine.command(@backingInt(eth_mode.Mode.operation));
    try std.testing.expectEqual(eth_mode.Mode.operation, machine.last_refused.?);
    try std.testing.expectEqual(@as(u32, @backingInt(eth_mode.Mode.reset)), machine.status());
    try std.testing.expectEqual(@as(u32, 1), machine.refused);
}

test "commanding the current mode does not change or refuse it" {
    var machine = eth_mode.Machine{};
    machine.command(@backingInt(eth_mode.Mode.disable));
    machine.command(@backingInt(eth_mode.Mode.disable));
    try std.testing.expectEqual(@as(u32, 0), machine.changes);
    try std.testing.expectEqual(@as(u32, 2), machine.commands);
    try std.testing.expectEqual(@as(u32, 0), machine.refused);
}

test "operation is the mode in which the rings live" {
    var machine = eth_mode.Machine{};
    machine.command(@backingInt(eth_mode.Mode.operation));
    try std.testing.expect(machine.operational());
}

test "GWCA default open re-enters operation after configuring queues" {
    var machine = eth_mode.Machine{};
    for ([_]eth_mode.Mode{ .operation, .config, .operation }) |mode| {
        machine.command(@backingInt(mode));
    }
    try std.testing.expectEqual(@as(u32, 0), machine.refused);
    try std.testing.expectEqual(eth_mode.Mode.operation, machine.mode);
}

test "GWCA default open steps from operation back to config, as the bench does" {
    var machine: eth_mode.Machine = .{};
    for ([_]eth_mode.Mode{ .config, .disable, .operation, .config, .disable, .operation }) |mode| {
        machine.command(@backingInt(mode));
    }
    try std.testing.expectEqual(@as(u32, 0), machine.refused);
    try std.testing.expectEqual(eth_mode.Mode.operation, machine.mode);
}
