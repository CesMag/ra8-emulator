const std = @import("std");
const testing = std.testing;

const rst = @import("ra8").chip.periph.riic_reset;
const flag = @import("ra8").chip.periph.riic_flags;

const ice = flag.iccr1.ice;
const iicrst = flag.iccr1.iicrst;

test "ICE clear leaves the register file unpowered" {
    try testing.expect(!rst.powered(0));
    try testing.expect(!rst.powered(iicrst));
}

test "ICE set powers the register file whatever the reset says" {
    try testing.expect(rst.powered(ice));
    try testing.expect(rst.powered(ice | iicrst));
}

test "the machine runs only with ICE set and the reset released" {
    try testing.expect(rst.running(ice));
    try testing.expect(!rst.running(ice | iicrst));
    try testing.expect(!rst.running(iicrst));
    try testing.expect(!rst.running(0));
}

test "only the registers that move the bus are held" {
    try testing.expect(rst.movesBus(flag.reg.iccr2));
    try testing.expect(rst.movesBus(flag.reg.icdrt));
    try testing.expect(rst.movesBus(flag.reg.icdrr));
}

test "the bit rate and mode registers do not move the bus" {
    try testing.expect(!rst.movesBus(flag.reg.icmr1));
    try testing.expect(!rst.movesBus(flag.reg.icbrl));
    try testing.expect(!rst.movesBus(flag.reg.icbrh));
    try testing.expect(!rst.movesBus(flag.reg.icfer));
}

test "an unpowered access is answered by nobody" {
    try testing.expectEqual(rst.Verdict.unpowered, rst.verdict(0, flag.reg.icmr1));
    try testing.expectEqual(rst.Verdict.unpowered, rst.verdict(iicrst, flag.reg.iccr2));
}

test "a running block answers every register through the transfer path" {
    try testing.expectEqual(rst.Verdict.answer, rst.verdict(ice, flag.reg.iccr2));
    try testing.expectEqual(rst.Verdict.answer, rst.verdict(ice, flag.reg.icbrl));
}

test "the open sequence programs the bit rate while the reset is held" {
    // HUM Ch 39.3.2: ICE and IICRST both set is exactly when CKS, ICBRL,
    // ICBRH and ICFER are written, so all four have to land. They take the
    // ordinary path, which is what keeps ICMR3's ACKWP rule in force here.
    const held = ice | iicrst;
    try testing.expectEqual(rst.Verdict.answer, rst.verdict(held, flag.reg.icmr1));
    try testing.expectEqual(rst.Verdict.answer, rst.verdict(held, flag.reg.icbrl));
    try testing.expectEqual(rst.Verdict.answer, rst.verdict(held, flag.reg.icbrh));
    try testing.expectEqual(rst.Verdict.answer, rst.verdict(held, flag.reg.icfer));
}

test "the bus stays held even though the settings land" {
    const held = ice | iicrst;
    try testing.expectEqual(rst.Verdict.held, rst.verdict(held, flag.reg.iccr2));
    try testing.expectEqual(rst.Verdict.held, rst.verdict(held, flag.reg.icdrt));
    try testing.expectEqual(rst.Verdict.held, rst.verdict(held, flag.reg.icdrr));
}
