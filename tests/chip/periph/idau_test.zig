//! Tests for src/chip/periph/idau.zig.

const std = @import("std");
const ra8 = @import("ra8");
const sau = ra8.chip.periph.sau;
const idau = sau.idau;
const State = sau.attribution.State;
const SramUnit = ra8.chip.periph.cpscu.sram.Unit;

const enable: u32 = 1 << 0;
const allns: u32 = 1 << 1;

fn program(unit: *sau.Sau, index: usize, base: u32, limit: u32, nsc: bool) void {
    const rlar = (limit & 0xFFFF_FFE0) | (if (nsc) @as(u32, 2) else 0) | 1;
    unit.table[index] = sau.Region.fromPair(base, rlar);
}

/// The ereader boot's boundary set: SRAM2 Non-secure, the rest Secure.
fn ereaderSram() SramUnit {
    return .{ .sabar = .{ 0x0008_0000, 0x0010_0000, 0x0010_0000, 0x001A_0000 } };
}

test "bit-28-clear code and SRAM are Secure but may be made callable" {
    const map = idau.Map{};
    for ([_]u32{ 0x0200_0000, 0x2200_0000 }) |address| {
        try std.testing.expectEqual(State.callable, map.answer(address).state);
    }
}

test "Secure peripherals stay Secure even under an NSC SAU region" {
    var unit = sau.Sau{ .ctrl = enable };
    program(&unit, 0, 0x4000_0000, 0x4FFF_FFFF, true);
    const map = idau.Map{};
    try std.testing.expectEqual(State.secure, map.answer(0x4000_8000).state);
    try std.testing.expectEqual(State.secure, map.attribute(&unit, 0x4000_8000).state);
}

test "bit 28 set is Non-secure with no SRAM boundaries" {
    const map = idau.Map{};
    for ([_]u32{ 0x1200_0000, 0x3200_0000, 0x5000_0000, 0x6000_0000, 0x8000_0000 }) |address| {
        try std.testing.expectEqual(State.non_secure, map.answer(address).state);
    }
}

test "the SRAM alias follows each bank's boundary" {
    const sram = ereaderSram();
    const map = idau.Map{ .sram = &sram };
    try std.testing.expectEqual(State.secure, map.answer(0x3200_0000).state);
    try std.testing.expectEqual(State.secure, map.answer(0x3208_0000).state);
    try std.testing.expectEqual(State.non_secure, map.answer(0x3210_0000).state);
    try std.testing.expectEqual(State.non_secure, map.answer(0x3217_FFFC).state);
    try std.testing.expectEqual(State.secure, map.answer(0x3218_0000).state);
}

test "a boundary inside a bank splits it" {
    var sram = SramUnit{};
    sram.sabar[1] = 0x000C_0000;
    const map = idau.Map{ .sram = &sram };
    try std.testing.expectEqual(State.secure, map.answer(0x320B_FFFC).state);
    try std.testing.expectEqual(State.non_secure, map.answer(0x320C_0000).state);
}

test "SRAM past the last bank and other bit-28 space stay Non-secure" {
    const sram = ereaderSram();
    const map = idau.Map{ .sram = &sram };
    try std.testing.expectEqual(State.non_secure, map.answer(0x321A_0000).state);
    try std.testing.expectEqual(State.non_secure, map.answer(0x1200_0000).state);
}

test "the SAU cannot make bit-28-clear code Non-secure, only callable" {
    var unit = sau.Sau{ .ctrl = enable };
    program(&unit, 0, 0x0200_0000, 0x0200_FFFF, false);
    program(&unit, 1, 0x0201_0000, 0x0201_0FFF, true);
    const map = idau.Map{};
    try std.testing.expectEqual(State.callable, map.attribute(&unit, 0x0200_0100).state);
    try std.testing.expectEqual(State.callable, map.attribute(&unit, 0x0201_0000).state);
    try std.testing.expectEqual(State.secure, map.attribute(&unit, 0x0300_0000).state);
}

test "attribution is never looser than the IDAU" {
    const sram = ereaderSram();
    const map = idau.Map{ .sram = &sram };
    const units = [_]sau.Sau{ .{}, .{ .ctrl = allns } };
    const addresses = [_]u32{ 0x0200_0000, 0x1200_0000, 0x2200_0000, 0x3200_0000, 0x3210_0000, 0x3218_0000, 0x5000_0000 };
    for (units) |unit| for (addresses) |address| {
        const got = map.attribute(&unit, address);
        if (got.exempt) continue;
        const floor = map.answer(address).state;
        try std.testing.expect(@backingInt(got.state) >= @backingInt(floor));
    };
}

test "the debug and system ranges stay exempt" {
    const map = idau.Map{};
    const unit = sau.Sau{ .ctrl = allns };
    try std.testing.expect(map.attribute(&unit, 0xE000_ED00).exempt);
}

test "each address names its HUM Figure 51.5 region" {
    const map = idau.Map{};
    const cases = [_]struct { address: u32, region: u8 }{
        .{ .address = 0x0200_0000, .region = 1 }, .{ .address = 0x0FFF_FFFF, .region = 1 },
        .{ .address = 0x1200_0000, .region = 2 }, .{ .address = 0x2200_0000, .region = 3 },
        .{ .address = 0x3210_0000, .region = 4 }, .{ .address = 0x4000_8000, .region = 5 },
        .{ .address = 0x5000_0000, .region = 6 }, .{ .address = 0x6000_0000, .region = 6 },
        .{ .address = 0xDFFF_FFFF, .region = 6 }, .{ .address = 0xE000_ED00, .region = 0 },
    };
    for (cases) |case| try std.testing.expectEqual(@as(?u8, case.region), map.answer(case.address).region);
}

test "TT from the Secure state reports IRVALID and IREGION" {
    const tt = ra8.chip.core.csel.tt;
    const map = idau.Map{};
    const unit = sau.Sau{ .ctrl = enable };
    const word = tt.respondWith(&unit, map.answer(0x3210_0000), 0x3210_0000, true);
    try std.testing.expect(word & tt.field.irvalid != 0);
    try std.testing.expectEqual(@as(u32, 4), word >> tt.field.iregion_shift);
    const code = tt.respondWith(&unit, map.answer(0x0200_0100), 0x0200_0100, true);
    try std.testing.expectEqual(@as(u32, 1), code >> tt.field.iregion_shift);
}

test "TT from the Non-secure state hides the IDAU region" {
    const tt = ra8.chip.core.csel.tt;
    const map = idau.Map{};
    const unit = sau.Sau{ .ctrl = enable };
    const word = tt.respondWith(&unit, map.answer(0x3210_0000), 0x3210_0000, false);
    try std.testing.expectEqual(@as(u32, 0), word & tt.field.irvalid);
    try std.testing.expectEqual(@as(u32, 0), word >> tt.field.iregion_shift);
}

test "RA8P1 SRAM0 and SRAM1 each follow their own boundary" {
    var sram = SramUnit{};
    sram.sabar = .{ 0x000C_0000, 0x0014_0000, 0x001F_E000, 0x001F_E000 };
    const map = idau.Map.forPart(&sram, true);
    try std.testing.expectEqual(State.secure, map.answer(0x320B_FFFC).state);
    try std.testing.expectEqual(State.non_secure, map.answer(0x320C_0000).state);
    try std.testing.expectEqual(State.non_secure, map.answer(0x320F_FFFC).state);
    try std.testing.expectEqual(State.secure, map.answer(0x3210_0000).state);
    try std.testing.expectEqual(State.secure, map.answer(0x3213_FFFC).state);
    try std.testing.expectEqual(State.non_secure, map.answer(0x3214_0000).state);
    try std.testing.expectEqual(State.non_secure, map.answer(0x3219_FFFC).state);
}

test "RA8P1 words 2 and 3 guard nothing past SRAM1" {
    var sram = SramUnit{};
    sram.sabar = .{ 0, 0, 0x001F_E000, 0x001F_E000 };
    const map = idau.Map.forPart(&sram, true);
    try std.testing.expectEqual(State.non_secure, map.answer(0x321A_0000).state);
    try std.testing.expectEqual(State.non_secure, map.answer(0x3218_0000).state);
}

test "the RA8D2 map reads the same address through a different bank" {
    var sram = SramUnit{};
    sram.sabar = .{ 0x0008_0000, 0x0014_0000, 0x0010_0000, 0x0018_0000 };
    try std.testing.expectEqual(State.non_secure, idau.Map.forPart(&sram, false).answer(0x3210_0000).state);
    try std.testing.expectEqual(State.secure, idau.Map.forPart(&sram, true).answer(0x3210_0000).state);
}

test "the code NS alias below the CMSAMON boundary answers Secure" {
    const map = idau.Map{ .code_secure = idau.cmsBytes(2) };
    try std.testing.expectEqual(State.secure, map.answer(0x1200_0000).state);
    try std.testing.expectEqual(State.secure, map.answer(0x1200_FFFF).state);
    try std.testing.expectEqual(State.non_secure, map.answer(0x1201_0000).state);
    try std.testing.expectEqual(State.callable, map.answer(0x0200_0000).state);
}

test "an NS SAU region cannot loosen Secure code MRAM" {
    var unit = sau.Sau{ .ctrl = enable };
    program(&unit, 0, 0x1200_0000, 0x120F_FFFF, false);
    const map = idau.Map{ .code_secure = idau.cmsBytes(1) };
    try std.testing.expectEqual(State.secure, map.attribute(&unit, 0x1200_7FFF).state);
    try std.testing.expectEqual(State.non_secure, map.attribute(&unit, 0x1200_8000).state);
}

test "no boundary keeps code on the bit-28 rule, a blank part covers 1 MB" {
    const map = idau.Map{};
    try std.testing.expectEqual(State.non_secure, map.answer(0x1200_0000).state);
    try std.testing.expect(idau.cmsBytes(0x1FF) >= 1024 * 1024);
}
