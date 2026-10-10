//! The responder half of the I3C channel: the synthetic controller's cycle
//! and what it refuses to count.
const std = @import("std");
const ra8 = @import("ra8");
const flag = ra8.chip.periph.i3c_flags;
const target = ra8.chip.periph.i3c_target;

fn armed(address: u7) target.Target {
    var responder = target.Target{};
    responder.open(@as(u32, address) << 1);
    return responder;
}

test "claiming an own address arms the responder" {
    var responder = armed(0x22);
    try std.testing.expect(responder.armed);
    try std.testing.expectEqual(@as(u7, 0x22), responder.own_address);
    try std.testing.expect(responder.quiet());
}

test "giving the address back up leaves the role" {
    var responder = armed(0x22);
    responder.open(0);
    try std.testing.expect(!responder.armed);
}

test "an own address I2C keeps for itself is refused" {
    var responder = target.Target{};
    responder.open(@as(u32, 0x7A) << 1);
    try std.testing.expect(!responder.armed);
    try std.testing.expectEqual(@as(u32, 1), responder.refused);
}

test "the first status poll starts a cycle with a byte to take" {
    var responder = armed(0x22);
    try std.testing.expectEqual(flag.ntst.rdbff0, responder.status());
    try std.testing.expectEqual(target.stimulus.seed, responder.byte);
}

test "taking the byte turns the buffer around" {
    var responder = armed(0x22);
    _ = responder.status();
    try std.testing.expectEqual(@as(u32, target.stimulus.seed), responder.receive());
    try std.testing.expectEqual(flag.ntst.tdbef0, responder.status());
}

test "the echo closes the cycle" {
    var responder = armed(0x22);
    _ = responder.status();
    const byte: u8 = @truncate(responder.receive());
    responder.transmit(byte);
    try std.testing.expectEqual(@as(u32, 1), responder.cycles);
    try std.testing.expect(!responder.mismatched);
    try std.testing.expect(!responder.quiet());
}

test "the written byte rotates per cycle" {
    var responder = armed(0x22);
    _ = responder.status();
    const first: u8 = @truncate(responder.receive());
    responder.transmit(first);
    _ = responder.status();
    const second: u8 = @truncate(responder.receive());
    try std.testing.expectEqual(target.stimulus.seed +% target.stimulus.step, second);
}

test "an echo that is not what was written is marked" {
    var responder = armed(0x22);
    _ = responder.status();
    _ = responder.receive();
    responder.transmit(0x00);
    try std.testing.expect(responder.mismatched);
    try std.testing.expectEqual(@as(u32, 1), responder.cycles);
}

test "an echo with nothing to echo is refused, not counted as a cycle" {
    var responder = armed(0x22);
    responder.transmit(0xAA);
    try std.testing.expectEqual(@as(u32, 0), responder.cycles);
    try std.testing.expectEqual(@as(u32, 1), responder.unprompted);
    // dev counted it and compared it against a byte nobody had read.
    try std.testing.expect(!responder.mismatched);
}

test "a drain with nothing written hands over nothing" {
    var responder = armed(0x22);
    try std.testing.expectEqual(@as(u32, 0), responder.receive());
    try std.testing.expectEqual(@as(u32, 1), responder.starved);
}

test "a second drain in the same cycle is not the same byte again" {
    var responder = armed(0x22);
    _ = responder.status();
    _ = responder.receive();
    try std.testing.expectEqual(@as(u32, 0), responder.receive());
    try std.testing.expectEqual(@as(u32, 1), responder.starved);
}

test "re-claiming the address restarts the cycle" {
    var responder = armed(0x22);
    _ = responder.status();
    responder.open(@as(u32, 0x30) << 1);
    try std.testing.expectEqual(target.Phase.idle, responder.phase);
    try std.testing.expectEqual(@as(u7, 0x30), responder.own_address);
}

test "ten cycles run end to end with every echo matching" {
    var responder = armed(0x22);
    for (0..10) |_| {
        _ = responder.status();
        const byte: u8 = @truncate(responder.receive());
        responder.transmit(byte);
    }
    try std.testing.expectEqual(@as(u32, 10), responder.cycles);
    try std.testing.expect(!responder.mismatched);
    try std.testing.expectEqual(@as(u32, 0), responder.unprompted);
}
