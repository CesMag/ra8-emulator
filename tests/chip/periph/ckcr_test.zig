//! The peripheral clock source selects: what the SREQ -> SRDY handshake
//! answers, and what PRCR eats.
const std = @import("std");
const ra8 = @import("ra8");
const ckcr = ra8.chip.periph.ckcr;
const prcr = ra8.chip.periph.prcr;

/// A protection model with PRC0 already open, the state a driver reaches
/// through RA8_PROTECTED_WRITE before it touches any of these.
fn unlocked() prcr.Prcr {
    var guard = prcr.Prcr.init();
    guard.write(prcr.win_base, 2, prcr.key.value | prcr.group.cgc);
    return guard;
}

/// The select named, by the name the report uses.
fn at(name: []const u8) u32 {
    for (&ckcr.slots) |one| {
        if (std.mem.eql(u8, one.name, name)) return one.address;
    }
    unreachable;
}

fn slotOf(name: []const u8) usize {
    return ckcr.indexOf(at(name)).?;
}

test "SRDY reads zero until something asks for a switch" {
    var guard = unlocked();
    var unit = ckcr.Ckcr.init(&guard);
    try std.testing.expectEqual(@as(u32, 0), unit.read(at("USBCKCR"), 1));
    try std.testing.expect(unit.quiet());
}

test "SREQ brings SRDY up, which is the wait the driver spins on first" {
    var guard = unlocked();
    var unit = ckcr.Ckcr.init(&guard);
    unit.write(at("USB60CKCR"), 1, ckcr.field.sreq);
    const seen = unit.read(at("USB60CKCR"), 1);
    try std.testing.expect(seen & ckcr.field.srdy != 0);
    try std.testing.expect(seen & ckcr.field.sreq != 0);
}

test "dropping SREQ takes SRDY down, which is the second wait" {
    var guard = unlocked();
    var unit = ckcr.Ckcr.init(&guard);
    const port = at("USB60CKCR");
    unit.write(port, 1, ckcr.field.sreq);
    unit.write(port, 1, 5 | ckcr.field.sreq);
    unit.write(port, 1, 5);
    try std.testing.expectEqual(@as(u32, 5), unit.read(port, 1));
    try std.testing.expectEqual(@as(u32, 1), unit.selects[slotOf("USB60CKCR")].switches);
}

test "the source lands whether or not SREQ rides with it" {
    var guard = unlocked();
    var unit = ckcr.Ckcr.init(&guard);
    const slot = slotOf("USBCKCR");
    unit.write(at("USBCKCR"), 1, 3 | ckcr.field.sreq);
    try std.testing.expectEqual(@as(u8, 3), unit.selects[slot].sel);
    unit.write(at("USBCKCR"), 1, 3);
    try std.testing.expectEqual(@as(u8, 3), unit.selects[slot].sel);
}

test "SRDY is read only: a store cannot set it and a store cannot hold it up" {
    var guard = unlocked();
    var unit = ckcr.Ckcr.init(&guard);
    unit.write(at("OCTACKCR"), 1, ckcr.field.srdy);
    try std.testing.expectEqual(@as(u32, 0), unit.read(at("OCTACKCR"), 1));
}

test "the selects do not share a handshake" {
    var guard = unlocked();
    var unit = ckcr.Ckcr.init(&guard);
    unit.write(at("USBCKCR"), 1, ckcr.field.sreq);
    try std.testing.expectEqual(@as(u32, 0), unit.read(at("CANFDCKCR"), 1));
    try std.testing.expectEqual(@as(u32, 0), unit.read(at("SCICKCR"), 1));
    try std.testing.expectEqual(@as(u32, 0), unit.read(at("ESWPCKCR"), 1));
    try std.testing.expect(unit.read(at("USBCKCR"), 1) & ckcr.field.srdy != 0);
}

test "the SCI and Ethernet-switch branches take the same handshake" {
    var guard = unlocked();
    var unit = ckcr.Ckcr.init(&guard);
    for ([_][]const u8{ "SCICKCR", "ESWCKCR", "ESWPCKCR" }) |name| {
        const port = at(name);
        unit.write(port, 1, ckcr.field.sreq);
        try std.testing.expect(unit.read(port, 1) & ckcr.field.srdy != 0);
        unit.write(port, 1, 8 | ckcr.field.sreq);
        unit.write(port, 1, 8);
        try std.testing.expectEqual(@as(u32, 8), unit.read(port, 1));
        try std.testing.expectEqual(@as(u32, 1), unit.selects[slotOf(name)].switches);
    }
}

test "a store with PRC0 locked is eaten and the branch does not move" {
    var guard = prcr.Prcr.init();
    var unit = ckcr.Ckcr.init(&guard);
    unit.write(at("ESWCKCR"), 1, 5 | ckcr.field.sreq);
    try std.testing.expectEqual(@as(u32, 0), unit.read(at("ESWCKCR"), 1));
    try std.testing.expectEqual(@as(u32, 1), unit.dropped_locked);
}

test "the three runs of adjacent selects are three bus entries" {
    var guard = unlocked();
    var unit = ckcr.Ckcr.init(&guard);
    var covered: usize = 0;
    for (0..ckcr.windows.len) |which| {
        const entry = unit.block(which);
        covered += entry.size;
        for (&ckcr.slots) |one| {
            if (one.address >= entry.base and one.address < entry.base + entry.size) continue;
        }
    }
    try std.testing.expectEqual(ckcr.slots.len, covered);
    for (&ckcr.slots) |one| try std.testing.expect(ckcr.indexOf(one.address) != null);
    try std.testing.expect(ckcr.indexOf(0x4001_E056) == null);
}

test "a run that switched nothing stays out of the report" {
    var guard = unlocked();
    var unit = ckcr.Ckcr.init(&guard);
    _ = unit.read(at("SCICKCR"), 1);
    try std.testing.expect(unit.quiet());
    unit.write(at("SCICKCR"), 1, ckcr.field.sreq);
    try std.testing.expect(!unit.quiet());
}
