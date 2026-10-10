//! The peripheral clock dividers: what takes inside the switch window,
//! what does not take outside it, and what PRCR eats before either.
const std = @import("std");
const ra8 = @import("ra8");
const ckcr = ra8.chip.periph.ckcr;
const ckdiv = ra8.chip.periph.ckdiv;
const prcr = ra8.chip.periph.prcr;

/// A protection model with PRC0 already open, the state a driver reaches
/// through RA8_PROTECTED_WRITE before it touches any of these.
fn unlocked() prcr.Prcr {
    var guard = prcr.Prcr.init();
    guard.write(prcr.win_base, 2, prcr.key.value | prcr.group.cgc);
    return guard;
}

/// The divider named, by the name the report uses.
fn at(name: []const u8) u32 {
    for (&ckdiv.slots) |one| {
        if (std.mem.eql(u8, one.name, name)) return one.address;
    }
    unreachable;
}

fn slotOf(name: []const u8) usize {
    return ckdiv.indexOf(at(name)).?;
}

/// The select this divider is written inside the window of.
fn selectOf(name: []const u8) u32 {
    return ckdiv.slots[slotOf(name)].select;
}

/// Step 1 and 2 of the switching procedure: ask, and see SRDY come up.
fn openWindow(branches: *ckcr.Ckcr, name: []const u8) void {
    branches.write(selectOf(name), 1, ckcr.field.sreq);
}

test "a divider reads its reset code, which is zero and means /1" {
    var guard = unlocked();
    var branches = ckcr.Ckcr.init(&guard);
    var unit = ckdiv.Ckdiv.init(&guard, &branches);
    try std.testing.expectEqual(@as(u32, 0), unit.read(at("SCICKDIVCR"), 1));
    try std.testing.expect(unit.quiet());
}

test "a store inside the switch window takes" {
    var guard = unlocked();
    var branches = ckcr.Ckcr.init(&guard);
    var unit = ckdiv.Ckdiv.init(&guard, &branches);
    openWindow(&branches, "SCICKDIVCR");
    unit.write(at("SCICKDIVCR"), 1, 3);
    try std.testing.expectEqual(@as(u32, 3), unit.read(at("SCICKDIVCR"), 1));
    try std.testing.expectEqual(@as(u32, 1), unit.dividers[slotOf("SCICKDIVCR")].writes);
}

test "a store with the branch running does not take, and is counted" {
    var guard = unlocked();
    var branches = ckcr.Ckcr.init(&guard);
    var unit = ckdiv.Ckdiv.init(&guard, &branches);
    unit.write(at("ESWCKDIVCR"), 1, 2);
    try std.testing.expectEqual(@as(u32, 0), unit.read(at("ESWCKDIVCR"), 1));
    const slot = slotOf("ESWCKDIVCR");
    try std.testing.expectEqual(@as(u32, 1), unit.dividers[slot].ungated);
    try std.testing.expectEqual(@as(u32, 0), unit.dividers[slot].writes);
}

test "the driver can come back inside the window and the store lands" {
    var guard = unlocked();
    var branches = ckcr.Ckcr.init(&guard);
    var unit = ckdiv.Ckdiv.init(&guard, &branches);
    unit.write(at("ESWCKDIVCR"), 1, 2);
    openWindow(&branches, "ESWCKDIVCR");
    unit.write(at("ESWCKDIVCR"), 1, 2);
    try std.testing.expectEqual(@as(u32, 2), unit.read(at("ESWCKDIVCR"), 1));
}

test "dropping SREQ shuts the window again" {
    var guard = unlocked();
    var branches = ckcr.Ckcr.init(&guard);
    var unit = ckdiv.Ckdiv.init(&guard, &branches);
    const select = selectOf("ESWPCKDIVCR");
    openWindow(&branches, "ESWPCKDIVCR");
    unit.write(at("ESWPCKDIVCR"), 1, 1);
    branches.write(select, 1, 5);
    unit.write(at("ESWPCKDIVCR"), 1, 4);
    try std.testing.expectEqual(@as(u32, 1), unit.read(at("ESWPCKDIVCR"), 1));
}

test "PRC0 locked drops the store before the window is even asked about" {
    var guard = prcr.Prcr.init();
    var branches = ckcr.Ckcr.init(&guard);
    var unit = ckdiv.Ckdiv.init(&guard, &branches);
    unit.write(at("USBCKDIVCR"), 1, 6);
    try std.testing.expectEqual(@as(u32, 0), unit.read(at("USBCKDIVCR"), 1));
    try std.testing.expectEqual(@as(u32, 1), unit.dropped_locked);
    try std.testing.expectEqual(@as(u32, 0), unit.dividers[slotOf("USBCKDIVCR")].ungated);
}

test "only CKDIV is retained, the reserved bits above it read zero" {
    var guard = unlocked();
    var branches = ckcr.Ckcr.init(&guard);
    var unit = ckdiv.Ckdiv.init(&guard, &branches);
    openWindow(&branches, "CANFDCKDIVCR");
    unit.write(at("CANFDCKDIVCR"), 1, 0xF5);
    try std.testing.expectEqual(@as(u32, 5), unit.read(at("CANFDCKDIVCR"), 1));
}

test "each divider follows its own branch, not another one's window" {
    var guard = unlocked();
    var branches = ckcr.Ckcr.init(&guard);
    var unit = ckdiv.Ckdiv.init(&guard, &branches);
    openWindow(&branches, "USBCKDIVCR");
    unit.write(at("USB60CKDIVCR"), 1, 7);
    try std.testing.expectEqual(@as(u32, 0), unit.read(at("USB60CKDIVCR"), 1));
    try std.testing.expectEqual(@as(u32, 1), unit.dividers[slotOf("USB60CKDIVCR")].ungated);
}

test "reads are never gated, with PRC0 shut or the branch running" {
    var guard = unlocked();
    var branches = ckcr.Ckcr.init(&guard);
    var unit = ckdiv.Ckdiv.init(&guard, &branches);
    openWindow(&branches, "OCTACKDIVCR");
    unit.write(at("OCTACKDIVCR"), 1, 9);
    var shut = prcr.Prcr.init();
    unit.protection = &shut;
    try std.testing.expectEqual(@as(u32, 9), unit.read(at("OCTACKDIVCR"), 1));
}

test "an address inside a window that is not a divider answers zero" {
    var guard = unlocked();
    var branches = ckcr.Ckcr.init(&guard);
    var unit = ckdiv.Ckdiv.init(&guard, &branches);
    try std.testing.expectEqual(@as(u32, 0), unit.read(0x4001_E070, 1));
    try std.testing.expect(unit.quiet());
}

test "every divider names a select this model actually answers for" {
    for (&ckdiv.slots) |one| {
        try std.testing.expect(ckcr.indexOf(one.select) != null);
    }
}

test "the windows cover every divider and nothing else" {
    for (&ckdiv.slots) |one| {
        var covered = false;
        for (&ckdiv.windows) |win| {
            if (one.address >= win.base and one.address < win.base + win.span) covered = true;
        }
        try std.testing.expect(covered);
    }
}
