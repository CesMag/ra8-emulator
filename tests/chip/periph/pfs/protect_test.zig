const std = @import("std");
const ra8 = @import("ra8");
const protect = ra8.chip.periph.pfs.protect;

test "the gate resets locked, so a pin write before any unlock goes nowhere" {
    const guard = protect.Protect{};
    try std.testing.expect(!guard.allows());
    try std.testing.expectEqual(protect.field.b0wi, guard.secure.word);
}

test "setting PFSWE while B0WI stands does nothing" {
    var gate = protect.Gate{};
    gate.store(protect.field.pfswe);
    try std.testing.expect(!gate.open());
}

test "the documented two-step sequence opens the gate" {
    var gate = protect.Gate{};
    gate.store(0);
    gate.store(protect.field.pfswe);
    try std.testing.expect(gate.open());
}

test "the lock sequence closes it again and puts B0WI back" {
    var gate = protect.Gate{};
    gate.store(0);
    gate.store(protect.field.pfswe);
    gate.store(0);
    gate.store(protect.field.b0wi);
    try std.testing.expect(!gate.open());
    try std.testing.expectEqual(protect.field.b0wi, gate.word);
}

test "one store carrying both bits sets both, because B0WI is read as it stood" {
    var gate = protect.Gate{};
    gate.store(0);
    gate.store(protect.field.pfswe | protect.field.b0wi);
    try std.testing.expect(gate.open());
}

test "an ignored key write is counted" {
    var guard = protect.Protect{};
    guard.write(protect.off.pwprs, protect.field.pfswe);
    try std.testing.expectEqual(@as(u32, 1), guard.ignored_keys);
    try std.testing.expect(!guard.allows());
}

test "unlocking the non-secure path alone does not let pin writes through" {
    var guard = protect.Protect{};
    guard.write(protect.off.pwpr, 0);
    guard.write(protect.off.pwpr, protect.field.pfswe);
    try std.testing.expect(!guard.allows());
    try std.testing.expect(guard.non_secure.open());
}

test "unlocking the secure path is what opens it" {
    var guard = protect.Protect{};
    guard.write(protect.off.pwprs, 0);
    guard.write(protect.off.pwprs, protect.field.pfswe);
    try std.testing.expect(guard.allows());
}

test "each path reads back its own word" {
    var guard = protect.Protect{};
    guard.write(protect.off.pwprs, 0);
    guard.write(protect.off.pwprs, protect.field.pfswe);
    try std.testing.expectEqual(protect.field.pfswe, guard.read(protect.off.pwprs));
    try std.testing.expectEqual(protect.field.b0wi, guard.read(protect.off.pwpr));
}

test "a quiet run says nothing" {
    const guard = protect.Protect{};
    try std.testing.expect(guard.quiet());
}
