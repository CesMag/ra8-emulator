//! Covers src/chip/core/cpu/mpu_check.zig.
const std = @import("std");
const ra8 = @import("ra8");
const mpu = ra8.chip.periph.mpu;
const mpu_check = ra8.chip.core.cpu.board_bus.mpu_check;

const ram_rw: [2]u32 = .{ 0x2000_0000, 0x2000_03FF };
const ram_ro: [2]u32 = .{ 0x2000_0200, 0x2000_023F };

/// Region 0 read-write for everyone over 1 KiB of RAM, region 1 a
/// read-only, privileged-only window inside it.
fn unitOf(ctrl: u32) mpu.Mpu {
    var unit = mpu.Mpu{};
    unit.table[0] = mpu.Region.fromPair(ram_rw[0] | mpu.field.rbar_ap_unprivileged, (ram_rw[1] & mpu.field.address) | mpu.field.rlar_enable);
    unit.table[1] = mpu.Region.fromPair(ram_ro[0] | mpu.field.rbar_ap_ro, (ram_ro[1] & mpu.field.address) | mpu.field.rlar_enable);
    unit.ctrl = ctrl;
    return unit;
}

const on = mpu.field.ctrl_enable;
const privdef = mpu.field.ctrl_enable | mpu.field.ctrl_privdefena;

test "a disabled MPU refuses nothing" {
    const unit = unitOf(0);
    try std.testing.expect(!mpu_check.refuses(&unit, ram_ro[0], .store, false));
    try std.testing.expect(!mpu_check.refuses(&unit, 0x6000_0000, .load, false));
}

test "the highest-numbered region decides: a store to the read-only window is refused" {
    const unit = unitOf(on);
    try std.testing.expect(mpu_check.refuses(&unit, ram_ro[0], .store, true));
    try std.testing.expect(!mpu_check.refuses(&unit, ram_ro[0], .load, true));
    try std.testing.expect(!mpu_check.refuses(&unit, ram_ro[0] - 4, .store, true));
}

test "unprivileged code is refused a privileged-only region even to read" {
    const unit = unitOf(on);
    try std.testing.expect(mpu_check.refuses(&unit, ram_ro[0], .load, false));
    try std.testing.expect(!mpu_check.refuses(&unit, ram_rw[0], .store, false));
}

test "the background refuses unprivileged code, and privileged code unless PRIVDEFENA" {
    const plain = unitOf(on);
    try std.testing.expect(mpu_check.refuses(&plain, 0x6000_0000, .load, true));
    try std.testing.expect(mpu_check.refuses(&plain, 0x6000_0000, .load, false));
    const default = unitOf(privdef);
    try std.testing.expect(!mpu_check.refuses(&default, 0x6000_0000, .load, true));
    try std.testing.expect(mpu_check.refuses(&default, 0x6000_0000, .load, false));
}

test "the PPB is never checked" {
    const unit = unitOf(on);
    try std.testing.expect(!mpu_check.refuses(&unit, mpu_check.ppb.first, .store, false));
    try std.testing.expect(!mpu_check.refuses(&unit, 0xE000_ED28, .load, false));
    try std.testing.expect(!mpu_check.refuses(&unit, mpu_check.ppb.last, .load, false));
    try std.testing.expect(mpu_check.refuses(&unit, mpu_check.ppb.last + 1, .load, false));
}

test "an unarmed check allows everything" {
    const unit = unitOf(on);
    var check: mpu_check.Check = .{ .unit = &unit };
    try std.testing.expect(check.allows(ram_ro[0], .store));
    try std.testing.expectEqual(@as(?u32, null), check.take());
}

test "an armed check remembers the first refused address and clears it on take" {
    const unit = unitOf(on);
    var check: mpu_check.Check = .{ .unit = &unit };
    check.arm(true, false);
    try std.testing.expect(!check.allows(ram_ro[0] + 8, .store));
    try std.testing.expect(!check.allows(ram_ro[0], .store));
    try std.testing.expectEqual(@as(?u32, ram_ro[0] + 8), check.take());
    try std.testing.expectEqual(@as(?u32, null), check.take());
    check.disarm();
    try std.testing.expect(check.allows(ram_ro[0], .store));
}

test "at a negative priority the MPU is off unless HFNMIENA" {
    const plain = unitOf(on);
    var check: mpu_check.Check = .{ .unit = &plain };
    check.arm(true, true);
    try std.testing.expect(check.allows(ram_ro[0], .store));
    const hfnmi = unitOf(on | mpu.field.ctrl_hfnmiena);
    var kept: mpu_check.Check = .{ .unit = &hfnmi };
    kept.arm(true, true);
    try std.testing.expect(!kept.allows(ram_ro[0], .store));
}

test "arming takes the privilege it is given" {
    const unit = unitOf(on);
    var check: mpu_check.Check = .{ .unit = &unit };
    check.arm(false, false);
    try std.testing.expect(!check.allows(ram_ro[0], .load));
    check.arm(true, false);
    try std.testing.expect(check.allows(ram_ro[0], .load));
}

test "a fetch is refused by execute-never, privilege, and the background" {
    var unit = unitOf(on);
    unit.table[1] = mpu.Region.fromPair(ram_ro[0] | mpu.field.rbar_xn | mpu.field.rbar_ap_unprivileged, (ram_ro[1] & mpu.field.address) | mpu.field.rlar_enable);
    const check: mpu_check.Check = .{ .unit = &unit };
    try std.testing.expect(check.refusesFetch(ram_ro[0], true, false));
    try std.testing.expect(!check.refusesFetch(ram_rw[0], false, false));
    try std.testing.expect(check.refusesFetch(0x6000_0000, true, false));
}

test "a fetch at negative priority is not checked unless HFNMIENA" {
    var unit = unitOf(on);
    unit.table[1] = mpu.Region.fromPair(ram_ro[0] | mpu.field.rbar_xn, (ram_ro[1] & mpu.field.address) | mpu.field.rlar_enable);
    const check: mpu_check.Check = .{ .unit = &unit };
    try std.testing.expect(!check.refusesFetch(ram_ro[0], true, true));
    unit.ctrl |= mpu.field.ctrl_hfnmiena;
    try std.testing.expect(check.refusesFetch(ram_ro[0], true, true));
}

test "lower checks the rest of the instruction as unprivileged and hands back the old privilege" {
    const unit = unitOf(on);
    var check: mpu_check.Check = .{ .unit = &unit };
    check.arm(true, false);
    try std.testing.expect(check.allows(ram_ro[0], .load));
    try std.testing.expect(check.lower());
    try std.testing.expect(!check.allows(ram_ro[0], .load));
    check.privileged = true;
    try std.testing.expect(check.allows(ram_ro[0], .load));
}

test "the Non-secure MPU judges accesses made in Non-secure state" {
    const secure_unit = unitOf(on);
    var ns_unit = mpu.Mpu{};
    ns_unit.ctrl = on;
    var state: ra8.chip.core.banked.State = .secure;
    var check: mpu_check.Check = .{ .unit = &secure_unit, .unit_ns = &ns_unit, .state = &state };
    check.arm(true, false);
    try std.testing.expect(!check.allows(ram_ro[0], .store));
    try std.testing.expect(check.allows(ram_rw[0], .store));
    state = .non_secure;
    check.arm(true, false);
    try std.testing.expect(!check.allows(0x2000_0000, .load));
    try std.testing.expect(check.refusesFetch(0x2000_0000, false, false));
    state = .secure;
    try std.testing.expect(!check.refusesFetch(0x2000_0000, false, false));
}

test "with no Non-secure MPU wired, Non-secure state keeps the one unit" {
    const unit = unitOf(on);
    const state: ra8.chip.core.banked.State = .non_secure;
    var check: mpu_check.Check = .{ .unit = &unit, .state = &state };
    check.arm(true, false);
    try std.testing.expect(!check.allows(ram_ro[0], .store));
    try std.testing.expect(check.allows(ram_rw[0], .store));
}

test "a disabled Non-secure MPU leaves Non-secure accesses unchecked" {
    const secure_unit = unitOf(on);
    const ns_unit = mpu.Mpu{};
    const state: ra8.chip.core.banked.State = .non_secure;
    var check: mpu_check.Check = .{ .unit = &secure_unit, .unit_ns = &ns_unit, .state = &state };
    check.arm(false, false);
    try std.testing.expect(!check.armed);
    try std.testing.expect(check.allows(ram_ro[0], .store));
}
