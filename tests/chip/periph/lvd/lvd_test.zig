//! PVD: the comparator against the board rail, DET's clear polarity, and the
//! lock that silently drops writes to the reset-only channels.
const std = @import("std");
const ra8 = @import("ra8");

const lvd = ra8.chip.periph.lvd;

const pvd1: u2 = 0;
const pvd4: u2 = 2;

/// PVDE set with the 2.80 V encoding: a monitor a healthy 3.3 V board passes.
const healthy: u8 = lvd.compare.enable | 0x09;
/// PVDE set with the 3.86 V encoding, which a 3.3 V rail sits below.
const above_rail: u8 = lvd.compare.enable | 0x03;

fn armed(unit: *lvd.Lvd, edge: lvd.Edge, level: u8) void {
    unit.write(lvd.at(pvd1, .cr1), 1, @backingInt(edge));
    unit.write(lvd.at(pvd1, .cmpcr), 1, level);
}

test "the threshold table only answers for the encodings HUM allows" {
    try std.testing.expectEqual(@as(?u16, null), lvd.detectVoltage(0x02));
    try std.testing.expectEqual(@as(?u16, null), lvd.detectVoltage(0x10));
    try std.testing.expectEqual(@as(?u16, 3860), lvd.detectVoltage(lvd.level_min));
    try std.testing.expectEqual(@as(?u16, 1710), lvd.detectVoltage(lvd.level_max));
    try std.testing.expectEqual(@as(?u16, 2800), lvd.detectVoltage(0x09));
}

test "a monitor that was never enabled reports no monitor, not a healthy rail" {
    var unit = lvd.Lvd.init();
    try std.testing.expectEqual(@as(u32, 0), unit.read(lvd.at(pvd1, .sr), 1));
}

test "a threshold under the rail reads MON above with DET clear" {
    var unit = lvd.Lvd.init();
    armed(&unit, .fall, healthy);
    try std.testing.expectEqual(@as(u32, lvd.status.mon), unit.read(lvd.at(pvd1, .sr), 1));
}

test "a threshold over the rail reads MON below" {
    var unit = lvd.Lvd.init();
    armed(&unit, .fall, above_rail);
    try std.testing.expectEqual(@as(u32, 0), unit.read(lvd.at(pvd1, .sr), 1));
}

test "enabling the detector is a baseline, not a crossing" {
    var unit = lvd.Lvd.init();
    armed(&unit, .both, above_rail);
    try std.testing.expect(!unit.channels[pvd1].det);
    try std.testing.expectEqual(@as(u32, 0), unit.channels[pvd1].crossings);
}

test "raising the threshold past the rail latches DET on a fall monitor" {
    var unit = lvd.Lvd.init();
    armed(&unit, .fall, healthy);
    unit.write(lvd.at(pvd1, .cmpcr), 1, above_rail);
    try std.testing.expectEqual(@as(u32, lvd.status.det), unit.read(lvd.at(pvd1, .sr), 1));
    try std.testing.expectEqual(@as(u32, 1), unit.channels[pvd1].crossings);
}

test "a fall monitor ignores the crossing back above the threshold" {
    var unit = lvd.Lvd.init();
    armed(&unit, .rise, healthy);
    unit.write(lvd.at(pvd1, .cmpcr), 1, above_rail);
    try std.testing.expect(!unit.channels[pvd1].det);
    // The crossing happened, the edge selector just did not want it.
    try std.testing.expectEqual(@as(u32, 1), unit.channels[pvd1].crossings);
}

test "a rise monitor latches DET coming back above the threshold" {
    var unit = lvd.Lvd.init();
    armed(&unit, .rise, above_rail);
    unit.write(lvd.at(pvd1, .cmpcr), 1, healthy);
    try std.testing.expect(unit.channels[pvd1].det);
}

test "DET is write-0-to-clear and a write of 1 clears nothing" {
    var unit = lvd.Lvd.init();
    armed(&unit, .both, healthy);
    unit.write(lvd.at(pvd1, .cmpcr), 1, above_rail);
    unit.write(lvd.at(pvd1, .sr), 1, lvd.status.det);
    try std.testing.expect(unit.channels[pvd1].det);
    try std.testing.expectEqual(@as(u32, 1), unit.channels[pvd1].refused_clears);
    unit.write(lvd.at(pvd1, .sr), 1, 0);
    try std.testing.expect(!unit.channels[pvd1].det);
}

test "a reserved PVDLVL encoding leaves no comparator behind" {
    var unit = lvd.Lvd.init();
    armed(&unit, .both, lvd.compare.enable | 0x1F);
    try std.testing.expectEqual(@as(u32, 0), unit.read(lvd.at(pvd1, .sr), 1));
    try std.testing.expectEqual(@as(u32, 1), unit.channels[pvd1].reserved_level);
}

test "clearing PVDE takes the monitor back off" {
    var unit = lvd.Lvd.init();
    armed(&unit, .both, healthy);
    unit.write(lvd.at(pvd1, .cmpcr), 1, 0x09);
    try std.testing.expectEqual(@as(u32, 0), unit.read(lvd.at(pvd1, .sr), 1));
}

test "PVDmCR0 reads back its reserved marker bit set" {
    var unit = lvd.Lvd.init();
    unit.write(lvd.at(pvd1, .cr0), 1, lvd.control.rie);
    const value = unit.read(lvd.at(pvd1, .cr0), 1);
    try std.testing.expectEqual(@as(u32, lvd.control.rie | lvd.control.m_marker), value);
}

test "PVDmCR1 keeps only IDTSEL and IRQSEL" {
    var unit = lvd.Lvd.init();
    unit.write(lvd.at(pvd1, .cr1), 1, 0xFF);
    try std.testing.expectEqual(@as(u32, lvd.irq.writable), unit.read(lvd.at(pvd1, .cr1), 1));
}

test "PVDmFCR keeps only RHSEL" {
    var unit = lvd.Lvd.init();
    // RI first: the rise-detect band is prohibited until the reset path is
    // armed, so this test arms it to get at the mask underneath.
    unit.write(lvd.at(pvd1, .cr0), 1, lvd.control.ri);
    unit.write(lvd.at(pvd1, .fcr), 1, 0xFE);
    try std.testing.expectEqual(@as(u32, 0), unit.read(lvd.at(pvd1, .fcr), 1));
    unit.write(lvd.at(pvd1, .fcr), 1, 0xFF);
    try std.testing.expectEqual(@as(u32, lvd.hysteresis.rhsel), unit.read(lvd.at(pvd1, .fcr), 1));
    try std.testing.expect(unit.bands.quiet());
}

test "the rise-detect band is refused until RI arms the reset path" {
    var unit = lvd.Lvd.init();
    unit.write(lvd.at(pvd1, .fcr), 1, lvd.hysteresis.rhsel);
    try std.testing.expectEqual(@as(u32, 0), unit.read(lvd.at(pvd1, .fcr), 1));
    try std.testing.expectEqual(@as(u32, 1), unit.bands.bands);
    try std.testing.expect(!unit.quiet());
    // Arm it and the same store lands.
    unit.write(lvd.at(pvd1, .cr0), 1, lvd.control.ri);
    unit.write(lvd.at(pvd1, .fcr), 1, lvd.hysteresis.rhsel);
    try std.testing.expectEqual(@as(u32, lvd.hysteresis.rhsel), unit.read(lvd.at(pvd1, .fcr), 1));
    try std.testing.expectEqual(@as(u32, 1), unit.bands.bands);
}

test "RN is refused while the rise-detect band stands, and the rest of the store lands" {
    var unit = lvd.Lvd.init();
    unit.write(lvd.at(pvd1, .cr0), 1, lvd.control.ri);
    unit.write(lvd.at(pvd1, .fcr), 1, lvd.hysteresis.rhsel);
    unit.write(lvd.at(pvd1, .cr0), 1, lvd.control.ri | lvd.control.rn | lvd.control.rie);
    const cr0 = unit.read(lvd.at(pvd1, .cr0), 1);
    try std.testing.expectEqual(@as(u32, 0), cr0 & lvd.control.rn);
    try std.testing.expectEqual(@as(u32, lvd.control.rie), cr0 & lvd.control.rie);
    try std.testing.expectEqual(@as(u32, 1), unit.bands.negations);
}

test "an n-series channel is gated by neither rule" {
    var unit = lvd.Lvd.init();
    unit.write(lvd.pvdlr_at, 1, 0);
    unit.write(lvd.at(pvd4, .fcr), 1, lvd.hysteresis.rhsel);
    try std.testing.expectEqual(@as(u32, lvd.hysteresis.rhsel), unit.read(lvd.at(pvd4, .fcr), 1));
    try std.testing.expect(unit.bands.quiet());
}

test "PVDLR locks the reset-only channels out of reset" {
    var unit = lvd.Lvd.init();
    try std.testing.expectEqual(@as(u32, lvd.lock.bit), unit.read(lvd.pvdlr_at, 1));
    unit.write(lvd.at(pvd4, .cmpcr), 1, healthy);
    try std.testing.expectEqual(@as(u32, 0), unit.read(lvd.at(pvd4, .cmpcr), 1));
    try std.testing.expectEqual(@as(u32, 1), unit.dropped);
}

test "one write of zero to PVDLR releases the lock" {
    var unit = lvd.Lvd.init();
    unit.write(lvd.pvdlr_at, 1, 0);
    try std.testing.expectEqual(@as(u32, 0), unit.read(lvd.pvdlr_at, 1));
    unit.write(lvd.at(pvd4, .cmpcr), 1, healthy);
    try std.testing.expectEqual(@as(u32, healthy), unit.read(lvd.at(pvd4, .cmpcr), 1));
    try std.testing.expectEqual(@as(u32, 0), unit.dropped);
}

test "a second PVDLR write re-locks for good, even another zero" {
    var unit = lvd.Lvd.init();
    unit.write(lvd.pvdlr_at, 1, 0);
    unit.write(lvd.pvdlr_at, 1, 0);
    try std.testing.expectEqual(@as(u32, lvd.lock.bit), unit.read(lvd.pvdlr_at, 1));
    unit.write(lvd.at(pvd4, .cr0), 1, lvd.control.rie);
    try std.testing.expectEqual(@as(u32, lvd.control.n_marker), unit.read(lvd.at(pvd4, .cr0), 1));
    try std.testing.expectEqual(@as(u32, 1), unit.dropped);
}

test "the lock never gates the monitor channels" {
    var unit = lvd.Lvd.init();
    unit.write(lvd.at(pvd1, .cmpcr), 1, healthy);
    try std.testing.expectEqual(@as(u32, healthy), unit.read(lvd.at(pvd1, .cmpcr), 1));
    try std.testing.expectEqual(@as(u32, 0), unit.dropped);
}

test "a reset-only channel has no status register to latch" {
    var unit = lvd.Lvd.init();
    unit.write(lvd.pvdlr_at, 1, 0);
    unit.write(lvd.at(pvd4, .cmpcr), 1, healthy);
    unit.write(lvd.at(pvd4, .cmpcr), 1, above_rail);
    try std.testing.expect(!unit.channels[pvd4].det);
    try std.testing.expectEqual(@as(u32, 1), unit.channels[pvd4].crossings);
}

test "the gaps inside each window read zero instead of aliasing a neighbour" {
    var unit = lvd.Lvd.init();
    unit.write(lvd.at(pvd1, .cmpcr), 1, healthy);
    try std.testing.expectEqual(@as(u32, 0), unit.read(lvd.control_base + 0x08, 1));
    try std.testing.expectEqual(@as(u32, 0), unit.read(lvd.filter_base + 0x08, 1));
}

test "a halfword read of the status window assembles both channels" {
    var unit = lvd.Lvd.init();
    armed(&unit, .fall, healthy);
    const pair = unit.read(lvd.status_base, 2);
    try std.testing.expectEqual(@as(u32, lvd.irq.idtsel & 1), pair & 0xFF);
    try std.testing.expectEqual(@as(u32, lvd.status.mon), pair >> 8);
}

test "an untouched block stays out of the report" {
    var unit = lvd.Lvd.init();
    try std.testing.expect(unit.quiet());
    unit.write(lvd.at(pvd1, .cmpcr), 1, healthy);
    try std.testing.expect(!unit.quiet());
}

test "armed says whether a latch would reach the CPU" {
    var unit = lvd.Lvd.init();
    try std.testing.expect(!unit.channels[pvd1].armed());
    unit.write(lvd.at(pvd1, .cr0), 1, lvd.control.rie | lvd.control.cmpe);
    try std.testing.expect(unit.channels[pvd1].armed());
    unit.write(lvd.pvdlr_at, 1, 0);
    unit.write(lvd.at(pvd4, .cr0), 1, lvd.control.rie);
    // An n channel has no interrupt path whatever RE says.
    try std.testing.expect(!unit.channels[pvd4].armed());
}

test "the divider lands while DFDIS is set, which is the driver's own order" {
    var unit = lvd.Lvd.init();
    unit.write(lvd.at(pvd1, .cr0), 1, lvd.control.dfdis);
    unit.write(lvd.at(pvd1, .cr0), 1, lvd.control.dfdis | 0x20);
    const value = unit.read(lvd.at(pvd1, .cr0), 1) & lvd.control.fsamp;
    try std.testing.expectEqual(@as(u32, 0x20), value);
    try std.testing.expectEqual(@as(u32, 0), unit.fields.filters);
}

test "the divider is refused while the filter runs, and the run says so" {
    var unit = lvd.Lvd.init();
    // The driver's order: DFDIS first on its own, then the divider.
    unit.write(lvd.at(pvd1, .cr0), 1, lvd.control.dfdis);
    unit.write(lvd.at(pvd1, .cr0), 1, lvd.control.dfdis | 0x10);
    // Drop DFDIS: the filter is now running with divider 0x10.
    unit.write(lvd.at(pvd1, .cr0), 1, 0x10);
    unit.write(lvd.at(pvd1, .cr0), 1, 0x20 | lvd.control.rie);
    const value = unit.read(lvd.at(pvd1, .cr0), 1);
    try std.testing.expectEqual(@as(u32, 0x10), value & lvd.control.fsamp);
    try std.testing.expectEqual(@as(u32, lvd.control.rie), value & lvd.control.rie);
    try std.testing.expectEqual(@as(u32, 1), unit.fields.filters);
    try std.testing.expect(!unit.quiet());
}

test "a CR0 read-modify-write that keeps the divider is not a refusal" {
    var unit = lvd.Lvd.init();
    unit.write(lvd.at(pvd1, .cr0), 1, lvd.control.dfdis);
    unit.write(lvd.at(pvd1, .cr0), 1, lvd.control.dfdis | 0x30);
    unit.write(lvd.at(pvd1, .cr0), 1, 0x30);
    unit.write(lvd.at(pvd1, .cr0), 1, 0x30 | lvd.control.rie);
    try std.testing.expectEqual(@as(u32, 0), unit.fields.filters);
}

test "setting DFDIS and moving FSAMP in one store is still a refusal" {
    var unit = lvd.Lvd.init();
    // The gate reads the DFDIS standing before the store, which is why the
    // driver reaches CR0 three times instead of once.
    unit.write(lvd.at(pvd1, .cr0), 1, lvd.control.dfdis | 0x20);
    try std.testing.expectEqual(
        @as(u32, 0),
        unit.read(lvd.at(pvd1, .cr0), 1) & lvd.control.fsamp,
    );
    try std.testing.expectEqual(@as(u32, 1), unit.fields.filters);
}

test "an n-series channel is gated the same way once PVDLR is released" {
    var unit = lvd.Lvd.init();
    unit.write(lvd.pvdlr_at, 1, 0);
    unit.write(lvd.at(pvd4, .cr0), 1, lvd.control.dfdis);
    unit.write(lvd.at(pvd4, .cr0), 1, lvd.control.dfdis | 0x10);
    unit.write(lvd.at(pvd4, .cr0), 1, 0x10);
    unit.write(lvd.at(pvd4, .cr0), 1, 0x30);
    try std.testing.expectEqual(
        @as(u32, 0x10),
        unit.read(lvd.at(pvd4, .cr0), 1) & lvd.control.fsamp,
    );
    try std.testing.expectEqual(@as(u32, 1), unit.fields.filters);
}
