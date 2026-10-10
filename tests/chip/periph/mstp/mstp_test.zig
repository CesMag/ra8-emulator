//! Tests for src/chip/periph/mstp/mstp.zig.
const std = @import("std");
const ra8 = @import("ra8");
const periph = ra8.chip.periph.registry;
const mod = ra8.chip.periph.mstp;

const Mstp = mod.Mstp;
const families = mod.families;
const reset_rest = mod.reset_rest;
const win_base = mod.win_base;
const win_span = mod.win_span;

const sci0 = 0x4035_8000;

const sci1 = 0x4035_8100;

const gpt7 = 0x4032_2700;
test "every peripheral but the SRAM bits starts stopped" {
    const modules = Mstp{};
    try std.testing.expect(modules.stopped(sci0));
    try std.testing.expect(modules.stopped(gpt7));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFF0), modules.regs[0]);
}

test "clearing a bit ungates exactly one instance" {
    var modules = Mstp{};
    modules.applyWrite(win_base + 4, 4, reset_rest & ~(@as(u32, 1) << 31));
    try std.testing.expect(!modules.stopped(sci0));
    try std.testing.expect(modules.stopped(sci1));
}

test "setting the bit again gates the instance back off" {
    var modules = Mstp{};
    modules.applyWrite(win_base + 4, 4, 0);
    try std.testing.expect(!modules.stopped(sci0));
    modules.applyWrite(win_base + 4, 4, reset_rest);
    try std.testing.expect(modules.stopped(sci0));
}

test "the read-back after an ungate returns what was written" {
    var modules = Mstp{};
    try std.testing.expectEqual(reset_rest, modules.readReg(win_base + 4, 4));
    modules.applyWrite(win_base + 4, 4, 0x1234_5678);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), modules.readReg(win_base + 4, 4));
}

test "byte and halfword accesses land on the right bytes" {
    var modules = Mstp{};
    modules.applyWrite(win_base + 4, 1, 0x12);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FF12), modules.regs[1]);
    modules.applyWrite(win_base + 6, 2, 0xABCD);
    try std.testing.expectEqual(@as(u32, 0xABCD_FF12), modules.regs[1]);
    try std.testing.expectEqual(@as(u32, 0x12), modules.readReg(win_base + 4, 1));
    try std.testing.expectEqual(@as(u32, 0xABCD), modules.readReg(win_base + 6, 2));
}

test "a write running off the end of the window stops at the end" {
    var modules = Mstp{};
    modules.applyWrite(win_base + win_span - 1, 4, 0xFFFF_FF00);
    try std.testing.expectEqual(@as(u32, 0x00FF_FFFF), modules.regs[4]);
    try std.testing.expectEqual(@as(u32, 0), modules.readReg(win_base + win_span, 4));
}

test "the six GPT channels that share MSTPE27 ungate together" {
    var modules = Mstp{};
    modules.applyWrite(win_base + 16, 4, reset_rest & ~(@as(u32, 1) << 27));
    var channel: u32 = 4;
    while (channel <= 9) : (channel += 1) {
        try std.testing.expect(!modules.stopped(0x4032_2000 + channel * 0x100));
    }
    try std.testing.expect(modules.stopped(0x4032_2300));
}

test "an address no family covers is never gated" {
    const modules = Mstp{};
    try std.testing.expect(!modules.stopped(0x4008_0000));
    try std.testing.expect(!modules.stopped(win_base));
    try std.testing.expect(!modules.stopped(0x4035_8000 - 4));
}

test "gated accesses are counted and named" {
    var modules = Mstp{};
    try std.testing.expect(modules.clean());
    modules.note(sci0, .read);
    modules.note(sci0 + 4, .write);
    modules.note(0x4031_0000, .read);
    try std.testing.expectEqual(@as(u32, 2), modules.gated_reads);
    try std.testing.expectEqual(@as(u32, 1), modules.gated_writes);
    try std.testing.expectEqualStrings("CRC", modules.last_gated);
    try std.testing.expect(!modules.clean());
}

test "reset returns every bit and every counter to power-on" {
    var modules = Mstp{};
    modules.applyWrite(win_base + 4, 4, 0);
    modules.note(sci0, .read);
    modules.reset();
    try std.testing.expect(modules.stopped(sci0));
    try std.testing.expect(modules.clean());
    try std.testing.expectEqualStrings("-", modules.last_gated);
}

test "no two families overlap" {
    for (&families, 0..) |*left, i| {
        for (families[i + 1 ..]) |right| {
            const left_end = left.base + left.span();
            const right_end = right.base + right.span();
            try std.testing.expect(left.base >= right_end or right.base >= left_end);
        }
    }
}

test "the bus gates a stopped peripheral and lets a running one through" {
    var bus = periph.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var modules = Mstp{};
    try bus.add(modules.block());
    bus.gate = modules.gate();

    bus.write(sci0, 4, 0xA5);
    try std.testing.expectEqual(@as(u32, 0), bus.read(sci0, 4));
    try std.testing.expectEqual(@as(u32, 1), modules.gated_reads);
    try std.testing.expectEqual(@as(u32, 1), modules.gated_writes);

    bus.write(win_base + 4, 4, reset_rest & ~(@as(u32, 1) << 31));
    try std.testing.expectEqual(reset_rest & ~(@as(u32, 1) << 31), bus.read(win_base + 4, 4));

    bus.write(sci0, 4, 0xA5);
    try std.testing.expectEqual(@as(u32, 0xA5), bus.read(sci0, 4));
    try std.testing.expectEqual(@as(u32, 1), modules.gated_reads);
}

test "the gate follows the Non-secure alias too" {
    var bus = periph.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var modules = Mstp{};
    try bus.add(modules.block());
    bus.gate = modules.gate();

    try std.testing.expectEqual(@as(u32, 0), bus.read(sci0 + periph.ns_offset, 4));
    try std.testing.expectEqual(@as(u32, 1), modules.gated_reads);
    try std.testing.expectEqual(reset_rest, bus.read(win_base + periph.ns_offset + 4, 4));
}

/// A bus with MSTPCRB bit 11 (USBHS) delegated to Non-secure, the way the
/// tz_nsc_cgc_usb secure boot leaves it (RA8EMU-354).
fn delegatedBus(bus: *periph.Bus, modules: *Mstp, unit: *ra8.chip.periph.pscu.Unit) !void {
    try bus.add(modules.block());
    modules.attribution = unit;
    modules.bus = bus;
    unit.words[1] = 1 << 11;
}

test "a Non-secure alias store moves a bit delegated to Non-secure" {
    var bus = periph.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var modules = Mstp{};
    var unit = ra8.chip.periph.pscu.Unit{};
    try delegatedBus(&bus, &modules, &unit);

    bus.write(win_base + periph.ns_offset + 4, 4, reset_rest & ~@as(u32, 1 << 11));
    try std.testing.expectEqual(reset_rest & ~@as(u32, 1 << 11), bus.read(win_base + 4, 4));
    try std.testing.expectEqual(@as(u32, 0), modules.masked_writes);
}

test "a Secure store still cannot move a delegated bit" {
    var bus = periph.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var modules = Mstp{};
    var unit = ra8.chip.periph.pscu.Unit{};
    try delegatedBus(&bus, &modules, &unit);

    bus.write(win_base + 4, 4, reset_rest & ~@as(u32, 1 << 11));
    try std.testing.expectEqual(reset_rest, bus.read(win_base + 4, 4));
    try std.testing.expectEqual(@as(u32, 1), modules.masked_writes);
}

test "a Non-secure alias store to an undelegated bit lands as before" {
    var bus = periph.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var modules = Mstp{};
    var unit = ra8.chip.periph.pscu.Unit{};
    try delegatedBus(&bus, &modules, &unit);

    bus.write(win_base + periph.ns_offset + 4, 4, reset_rest & ~@as(u32, 1 << 31));
    try std.testing.expectEqual(reset_rest & ~@as(u32, 1 << 31), bus.read(win_base + 4, 4));
}
