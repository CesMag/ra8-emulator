//! The MPU window: the region count it reports, and the table it captures.
const std = @import("std");
const ra8 = @import("ra8");
const mpu = ra8.chip.periph.mpu;
const memmap = ra8.chip.core.memmap;

/// A stand-in for the core that holds the PPB words the block reads and writes.
const FakePpb = struct {
    words: std.AutoHashMap(u32, u32),

    fn init(allocator: std.mem.Allocator) FakePpb {
        return .{ .words = std.AutoHashMap(u32, u32).init(allocator) };
    }

    fn deinit(self: *FakePpb) void {
        self.words.deinit();
    }

    pub fn readWord(self: *FakePpb, address: u32) !u32 {
        return self.words.get(address) orelse 0;
    }

    pub fn writeWord(self: *FakePpb, address: u32, value: u32) !void {
        try self.words.put(address, value);
    }
};

test "TYPE reports the region count this core implements" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    var unit = mpu.Mpu.init();

    try std.testing.expectEqual(@as(u32, 0), try ppb.readWord(memmap.mpu.type_));
    try unit.prime(&ppb);
    const value = try ppb.readWord(memmap.mpu.type_);
    try std.testing.expectEqual(mpu.geometry.type_value, value);
    try std.testing.expectEqual(
        @as(u32, mpu.geometry.regions),
        (value & 0x0000_FF00) >> mpu.geometry.dregion_shift,
    );
}

test "a store to TYPE is turned away and the count put back" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    var unit = mpu.Mpu.init();
    try unit.prime(&ppb);

    try ppb.writeWord(memmap.mpu.type_, 0);
    try unit.poll(&ppb);

    try std.testing.expectEqual(@as(u32, 1), unit.refused);
    try std.testing.expectEqual(mpu.geometry.type_value, try ppb.readWord(memmap.mpu.type_));
}

test "a region is captured out of the RBAR and RLAR pair that programs it" {
    var unit = mpu.Mpu.init();

    // Region 1 covers 0x2200_0000..0x2200_1FFF, read-only and not executable.
    _ = unit.observe(memmap.mpu.rnr, 1);
    _ = unit.observe(memmap.mpu.rbar, 0x2200_0000 | mpu.field.rbar_ap_ro | mpu.field.rbar_xn);
    _ = unit.observe(memmap.mpu.rlar, 0x2200_1FE0 | mpu.field.rlar_enable);

    const region = unit.table[1];
    try std.testing.expect(region.enabled);
    try std.testing.expect(region.read_only);
    try std.testing.expect(!region.executable);
    try std.testing.expectEqual(@as(u32, 0x2200_0000), region.base);
    try std.testing.expectEqual(@as(u32, 0x2200_1FFF), region.limit);
    try std.testing.expectEqual(@as(u32, 0x2000), region.bytes());
    try std.testing.expectEqual(@as(u8, 1), unit.programmed());
    try std.testing.expectEqual(@as(u8, 1), unit.readOnly());
}

test "the alias pairs reach the regions that follow the selected one" {
    var unit = mpu.Mpu.init();

    _ = unit.observe(memmap.mpu.rnr, 2);
    _ = unit.observe(memmap.mpu.rbar_a1, 0x0200_0000);
    _ = unit.observe(memmap.mpu.rlar_a1, 0x0200_0FE0 | mpu.field.rlar_enable);
    _ = unit.observe(memmap.mpu.rbar_a3, 0x4000_0000);
    _ = unit.observe(memmap.mpu.rlar_a3, 0x4000_0FE0 | mpu.field.rlar_enable);

    try std.testing.expectEqual(@as(u32, 0x0200_0000), unit.table[3].base);
    try std.testing.expect(unit.table[3].enabled);
    try std.testing.expectEqual(@as(u32, 0x4000_0000), unit.table[5].base);
    try std.testing.expect(unit.table[5].enabled);
    // Region 4 sat between them and nothing programmed it.
    try std.testing.expect(!unit.table[4].enabled);
}

test "a region with EN clear covers nothing" {
    var unit = mpu.Mpu.init();

    _ = unit.observe(memmap.mpu.rnr, 0);
    _ = unit.observe(memmap.mpu.rbar, 0x2200_0000);
    _ = unit.observe(memmap.mpu.rlar, 0x2200_1FE0);

    try std.testing.expect(!unit.table[0].enabled);
    try std.testing.expect(!unit.table[0].covers(0x2200_0010));
    try std.testing.expectEqual(@as(u32, 0), unit.table[0].bytes());
    try std.testing.expectEqual(@as(u8, 0), unit.programmed());
    try std.testing.expectEqual(@as(?mpu.Region, null), unit.regionFor(0x2200_0010));
}

test "CTRL.ENABLE moving each way is counted once" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    var unit = mpu.Mpu.init();
    try unit.prime(&ppb);

    try unit.poll(&ppb);
    try std.testing.expect(!unit.on());
    try std.testing.expectEqual(@as(u32, 0), unit.enables);

    try ppb.writeWord(memmap.mpu.ctrl, mpu.field.ctrl_enable | mpu.field.ctrl_privdefena);
    try unit.poll(&ppb);
    try unit.poll(&ppb);
    try std.testing.expect(unit.on());
    try std.testing.expect(unit.privilegedDefault());
    try std.testing.expectEqual(@as(u32, 1), unit.enables);
    try std.testing.expectEqual(@as(u32, 0), unit.disables);

    // ra8_mpu_configure disables before it reprogrammes, then re-enables.
    try ppb.writeWord(memmap.mpu.ctrl, 0);
    try unit.poll(&ppb);
    try ppb.writeWord(memmap.mpu.ctrl, mpu.field.ctrl_enable);
    try unit.poll(&ppb);
    try std.testing.expectEqual(@as(u32, 2), unit.enables);
    try std.testing.expectEqual(@as(u32, 1), unit.disables);
}

test "an overlap resolves to the highest-numbered region covering the address" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    var unit = mpu.Mpu.init();

    unit.table[1] = mpu.Region.fromPair(0x2200_0000, 0x2200_FFE0 | mpu.field.rlar_enable);
    unit.table[4] = mpu.Region.fromPair(
        0x2200_8000 | mpu.field.rbar_ap_ro,
        0x2200_8FE0 | mpu.field.rlar_enable,
    );

    const inner = unit.regionFor(0x2200_8100) orelse return error.NoRegion;
    try std.testing.expect(inner.read_only);
    const outer = unit.regionFor(0x2200_0100) orelse return error.NoRegion;
    try std.testing.expect(!outer.read_only);
    _ = &ppb;
}

test "a select value beyond the implemented set wraps into it" {
    try std.testing.expectEqual(@as(u8, 0), mpu.geometry.selects(0));
    try std.testing.expectEqual(@as(u8, 7), mpu.geometry.selects(7));
    try std.testing.expectEqual(@as(u8, 0), mpu.geometry.selects(8));
    try std.testing.expectEqual(@as(u8, 1), mpu.geometry.selects(9));
}

test "each region programmed through RNR keeps its own pair" {
    var unit = mpu.Mpu.init();

    // What ra8_mpu_configure's programRegion loop does: RNR, then the pair,
    // once per region. Over one RBAR word these all landed on each other.
    var region: u32 = 0;
    while (region < 4) : (region += 1) {
        _ = unit.observe(memmap.mpu.rnr, region);
        _ = unit.observe(memmap.mpu.rbar, 0x2200_0000 + region * 0x1000);
        _ = unit.observe(memmap.mpu.rlar, 0x2200_0FE0 + region * 0x1000 | mpu.field.rlar_enable);
    }

    try std.testing.expectEqual(@as(u8, 4), unit.programmed());
    try std.testing.expectEqual(@as(u32, 0x2200_0000), unit.table[0].base);
    try std.testing.expectEqual(@as(u32, 0x2200_3000), unit.table[3].base);
    try std.testing.expectEqual(@as(u32, 8), unit.banked);
}

test "clearing the unused tail leaves the programmed regions standing" {
    var unit = mpu.Mpu.init();

    _ = unit.observe(memmap.mpu.rnr, 0);
    _ = unit.observe(memmap.mpu.rbar, 0x2200_0000);
    _ = unit.observe(memmap.mpu.rlar, 0x2200_0FE0 | mpu.field.rlar_enable);

    // ra8_mpu_configure then walks the rest of the implemented set clearing
    // RLAR. Over one word this is the store that wiped the whole table.
    var region: u32 = 1;
    while (region < mpu.geometry.regions) : (region += 1) {
        _ = unit.observe(memmap.mpu.rnr, region);
        _ = unit.observe(memmap.mpu.rlar, 0);
    }

    try std.testing.expectEqual(@as(u8, 1), unit.programmed());
    try std.testing.expect(unit.table[0].enabled);
    try std.testing.expectEqual(@as(u32, 0x2200_0000), unit.table[0].base);
}

test "a store to RNR is the one that asks for the pairs to be put back" {
    var unit = mpu.Mpu.init();

    try std.testing.expectEqual(mpu.Mpu.Cue.rebank, unit.observe(memmap.mpu.rnr, 3));
    try std.testing.expectEqual(@as(u8, 3), unit.selected);
    try std.testing.expectEqual(mpu.Mpu.Cue.none, unit.observe(memmap.mpu.rbar, 0x2200_0000));
    try std.testing.expectEqual(mpu.Mpu.Cue.none, unit.observe(memmap.mpu.rlar, 0x2200_0FE0));
    // Nothing else in the window is banked, so nothing else asks.
    try std.testing.expectEqual(mpu.Mpu.Cue.rearm, unit.observe(memmap.mpu.ctrl, mpu.field.ctrl_enable));
    try std.testing.expectEqual(mpu.Mpu.Cue.none, unit.observe(memmap.mpu.mair0, 0x44));
    try std.testing.expectEqual(@as(u32, 2), unit.banked);
}

test "the pair put back is the region RNR now names, whole" {
    var unit = mpu.Mpu.init();

    // Attribute and shareability bits this model does not read still have to
    // survive a trip through the table, or a readback loses them.
    const rbar: u32 = 0x2200_0000 | (0b01 << 3) | mpu.field.rbar_ap_ro;
    const rlar: u32 = 0x2200_0FE0 | (0b010 << 1) | mpu.field.rlar_enable;
    _ = unit.observe(memmap.mpu.rnr, 5);
    _ = unit.observe(memmap.mpu.rbar, rbar);
    _ = unit.observe(memmap.mpu.rlar, rlar);

    _ = unit.observe(memmap.mpu.rnr, 0);
    try std.testing.expectEqual([2]u32{ 0, 0 }, unit.pairFor(0));

    _ = unit.observe(memmap.mpu.rnr, 5);
    try std.testing.expectEqual([2]u32{ rbar, rlar }, unit.pairFor(0));
    // The aliases follow it, and wrap with it.
    try std.testing.expectEqual(@as(u8, 6), unit.banks(1));
    try std.testing.expectEqual(@as(u8, 0), unit.banks(3));
}

test "a select beyond the implemented set banks into the wrapped region" {
    var unit = mpu.Mpu.init();

    _ = unit.observe(memmap.mpu.rnr, mpu.geometry.regions + 2);
    _ = unit.observe(memmap.mpu.rbar, 0x0200_0000);
    _ = unit.observe(memmap.mpu.rlar, 0x0200_0FE0 | mpu.field.rlar_enable);

    try std.testing.expectEqual(@as(u8, 2), unit.selected);
    try std.testing.expect(unit.table[2].enabled);
}

test "RBAR.AP[1] is what lets unprivileged code touch a region" {
    const open = mpu.Region.fromPair(
        0x2200_0000 | mpu.field.rbar_ap_unprivileged,
        0x2200_0FE0 | mpu.field.rlar_enable,
    );
    try std.testing.expect(open.unprivileged);
    const closed = mpu.Region.fromPair(0x2200_0000, 0x2200_0FE0 | mpu.field.rlar_enable);
    try std.testing.expect(!closed.unprivileged);
}

test "a privileged-only region refuses an unprivileged access either way" {
    const region = mpu.Region.fromPair(0x2200_0000, 0x2200_0FE0 | mpu.field.rlar_enable);
    try std.testing.expectEqual(mpu.Region.Refusal.privilege, region.refuses(.store, false));
    try std.testing.expectEqual(mpu.Region.Refusal.privilege, region.refuses(.fetch, false));
    try std.testing.expectEqual(mpu.Region.Refusal.allowed, region.refuses(.store, true));
}

test "privilege is checked before the region's own permissions" {
    const region = mpu.Region.fromPair(
        0x2200_0000 | mpu.field.rbar_ap_ro,
        0x2200_0FE0 | mpu.field.rlar_enable,
    );
    try std.testing.expectEqual(mpu.Region.Refusal.privilege, region.refuses(.store, false));
    try std.testing.expectEqual(mpu.Region.Refusal.permission, region.refuses(.store, true));
}

test "an open read-write region refuses nothing and needs no trap" {
    const region = mpu.Region.fromPair(
        0x2200_0000 | mpu.field.rbar_ap_unprivileged,
        0x2200_0FE0 | mpu.field.rlar_enable,
    );
    try std.testing.expectEqual(mpu.Region.Refusal.allowed, region.refuses(.store, false));
    try std.testing.expectEqual(mpu.Region.Refusal.allowed, region.refuses(.fetch, false));
    try std.testing.expect(!region.guarded());
}

test "any one of the three rules is enough to need a trap" {
    const enable = mpu.field.rlar_enable;
    const ro = mpu.Region.fromPair(mpu.field.rbar_ap_ro | mpu.field.rbar_ap_unprivileged, 0xFE0 | enable);
    const xn = mpu.Region.fromPair(mpu.field.rbar_xn | mpu.field.rbar_ap_unprivileged, 0xFE0 | enable);
    const priv = mpu.Region.fromPair(0, 0xFE0 | enable);
    try std.testing.expect(ro.guarded());
    try std.testing.expect(xn.guarded());
    try std.testing.expect(priv.guarded());
}

test "no permission bit refuses a privileged load" {
    const enable = mpu.field.rlar_enable;
    const unpriv = mpu.field.rbar_ap_unprivileged;
    const ro = mpu.Region.fromPair(mpu.field.rbar_ap_ro | unpriv, 0xFE0 | enable);
    const xn = mpu.Region.fromPair(mpu.field.rbar_xn | unpriv, 0xFE0 | enable);
    try std.testing.expectEqual(mpu.Region.Refusal.allowed, ro.refuses(.load, true));
    try std.testing.expectEqual(mpu.Region.Refusal.allowed, ro.refuses(.load, false));
    try std.testing.expectEqual(mpu.Region.Refusal.allowed, xn.refuses(.load, false));
}

test "a privileged-only region refuses a load as well" {
    const region = mpu.Region.fromPair(0x2200_0000, 0x2200_0FE0 | mpu.field.rlar_enable);
    try std.testing.expectEqual(mpu.Region.Refusal.privilege, region.refuses(.load, false));
    try std.testing.expectEqual(mpu.Region.Refusal.allowed, region.refuses(.load, true));
}
