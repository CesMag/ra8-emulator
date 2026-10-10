//! Covers src/chip/periph/dmac/dmac.zig: the channel window, the module gate over it,
//! and the software request that actually moves bytes in emulated memory.
const std = @import("std");
const ra8 = @import("ra8");

const dmac = ra8.chip.periph.dmac;
const dma_bank = ra8.chip.periph.dma_bank;
const xfer = ra8.chip.periph.dmac.xfer;
const store_memory = @import("../store_memory.zig");
const memmap = ra8.chip.core.memmap;

const source_at: u32 = memmap.sram_base + 0x100;
const dest_at: u32 = memmap.sram_base + 0x200;
const channel: usize = 0;

fn at(offset: u32) u32 {
    return dmac.channelAddress(channel) + offset;
}

/// A started module: DMAST.DMST up, the store a driver makes before arming
/// any channel and the one dev never looks at.
fn startedBank() dma_bank.Bank {
    var bank = dma_bank.Bank.init();
    bank.write(dma_bank.win_base, 1, dma_bank.field.dmst);
    return bank;
}

/// Program channel 0 for a byte copy of `count` units, both sides counting
/// up, and arm it. Nothing is triggered.
fn programCopy(unit: *dmac.Dmac, count: u32) void {
    unit.write(at(dmac.off.dmsar), 4, source_at);
    unit.write(at(dmac.off.dmdar), 4, dest_at);
    unit.write(at(dmac.off.dmcra), 4, count);
    unit.write(at(dmac.off.dmtmd), 2, 0);
    unit.write(at(dmac.off.dmamd), 2, 2 << xfer.field.sm_shift | 2 << xfer.field.dm_shift);
    unit.write(at(dmac.off.dmcnt), 1, dmac.field.dte);
}

/// A machine with board RAM and a known pattern at the source.
fn scene(core: store_memory.Guest) !void {
    var pattern: [16]u8 = undefined;
    for (&pattern, 0..) |*cell, index| cell.* = @intCast(0xA0 + index);
    try core.write(source_at, &pattern);
    try core.write(dest_at, &@as([16]u8, @splat(0)));
}

fn byteAt(core: store_memory.Guest, address: u32) !u8 {
    var cell: [1]u8 = undefined;
    try core.read(address, &cell);
    return cell[0];
}

test "a request with the module never started moves nothing" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    try scene(core);
    const bank = dma_bank.Bank.init();
    var unit = dmac.Dmac.init(&bank);
    unit.memory = core;
    programCopy(&unit, 4);
    unit.write(at(dmac.off.dmreq), 1, dmac.field.swreq);
    try std.testing.expectEqual(@as(u8, 0), try byteAt(core, dest_at));
    try std.testing.expectEqual(dmac.Refusal.stopped, unit.last_refusal.?);
}

test "a request on a channel that was never armed moves nothing" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    try scene(core);
    const bank = startedBank();
    var unit = dmac.Dmac.init(&bank);
    unit.memory = core;
    unit.write(at(dmac.off.dmsar), 4, source_at);
    unit.write(at(dmac.off.dmdar), 4, dest_at);
    unit.write(at(dmac.off.dmreq), 1, dmac.field.swreq);
    try std.testing.expectEqual(dmac.Refusal.disarmed, unit.last_refusal.?);
}

test "one request moves ONE unit with CLRS clear, not the whole count" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    try scene(core);
    const bank = startedBank();
    var unit = dmac.Dmac.init(&bank);
    unit.memory = core;
    programCopy(&unit, 4);
    unit.write(at(dmac.off.dmreq), 1, dmac.field.swreq);
    try std.testing.expectEqual(@as(u8, 0xA0), try byteAt(core, dest_at));
    try std.testing.expectEqual(@as(u8, 0), try byteAt(core, dest_at + 1));
    try std.testing.expectEqual(@as(u64, 1), unit.channels[channel].units);
    try std.testing.expectEqual(@as(u32, 3), unit.read(at(dmac.off.dmcra), 4));
}

test "the addresses are left where the unit stopped, so requests carry on" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    try scene(core);
    const bank = startedBank();
    var unit = dmac.Dmac.init(&bank);
    unit.memory = core;
    programCopy(&unit, 4);
    unit.write(at(dmac.off.dmreq), 1, dmac.field.swreq);
    unit.write(at(dmac.off.dmreq), 1, dmac.field.swreq);
    try std.testing.expectEqual(@as(u8, 0xA1), try byteAt(core, dest_at + 1));
    try std.testing.expectEqual(source_at + 2, unit.read(at(dmac.off.dmsar), 4));
    try std.testing.expectEqual(dest_at + 2, unit.read(at(dmac.off.dmdar), 4));
}

test "CLRS keeps the request asserted, so one store drains the count" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    try scene(core);
    const bank = startedBank();
    var unit = dmac.Dmac.init(&bank);
    unit.memory = core;
    programCopy(&unit, 4);
    unit.write(at(dmac.off.dmreq), 1, dmac.field.swreq | dmac.field.clrs);
    for (0..4) |index| {
        try std.testing.expectEqual(
            @as(u8, @intCast(0xA0 + index)),
            try byteAt(core, dest_at + @as(u32, @intCast(index))),
        );
    }
    try std.testing.expectEqual(@as(u64, 4), unit.channels[channel].units);
}

test "the count spent takes DMCNT.DTE down and latches DMSTS.DTIF" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    try scene(core);
    const bank = startedBank();
    var unit = dmac.Dmac.init(&bank);
    unit.memory = core;
    programCopy(&unit, 2);
    unit.write(at(dmac.off.dmreq), 1, dmac.field.swreq | dmac.field.clrs);
    try std.testing.expectEqual(@as(u32, 0), unit.read(at(dmac.off.dmcnt), 1));
    try std.testing.expectEqual(@as(u32, dmac.field.dtif), unit.read(at(dmac.off.dmsts), 1));
    try std.testing.expectEqual(@as(u32, 1), unit.channels[channel].completions);
}

test "a further request on a spent channel copies nothing, which dev gets wrong" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    try scene(core);
    const bank = startedBank();
    var unit = dmac.Dmac.init(&bank);
    unit.memory = core;
    programCopy(&unit, 2);
    unit.write(at(dmac.off.dmreq), 1, dmac.field.swreq | dmac.field.clrs);
    const moved = unit.channels[channel].units;
    unit.write(at(dmac.off.dmreq), 1, dmac.field.swreq | dmac.field.clrs);
    try std.testing.expectEqual(moved, unit.channels[channel].units);
    try std.testing.expectEqual(dmac.Refusal.disarmed, unit.last_refusal.?);
}

test "re-arming the channel reloads the counts" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    try scene(core);
    const bank = startedBank();
    var unit = dmac.Dmac.init(&bank);
    unit.memory = core;
    programCopy(&unit, 2);
    unit.write(at(dmac.off.dmreq), 1, dmac.field.swreq | dmac.field.clrs);
    unit.write(at(dmac.off.dmcra), 4, 2);
    unit.write(at(dmac.off.dmcnt), 1, dmac.field.dte);
    try std.testing.expectEqual(@as(u32, 2), unit.channels[channel].pending);
}

test "block mode moves one block per request, not the whole buffer" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    try scene(core);
    const bank = startedBank();
    var unit = dmac.Dmac.init(&bank);
    unit.memory = core;
    // Block mode and the block count have to be in before DMCNT.DTE goes
    // up: arming is what latches them, the same order silicon needs.
    programCopy(&unit, 4 << xfer.count.high_shift | 4);
    unit.write(at(dmac.off.dmcnt), 1, 0);
    unit.write(at(dmac.off.dmcrb), 4, 2);
    unit.write(at(dmac.off.dmtmd), 2, 2 << xfer.field.md_shift);
    unit.write(at(dmac.off.dmcnt), 1, dmac.field.dte);
    unit.write(at(dmac.off.dmreq), 1, dmac.field.swreq);
    try std.testing.expectEqual(@as(u64, 4), unit.channels[channel].units);
    try std.testing.expectEqual(@as(u8, 0xA3), try byteAt(core, dest_at + 3));
    try std.testing.expectEqual(@as(u8, 0), try byteAt(core, dest_at + 4));
    try std.testing.expectEqual(@as(u32, 1), unit.read(at(dmac.off.dmcrb), 4));
}

test "a decrementing source walks backwards, which dev treats as fixed" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    try scene(core);
    const bank = startedBank();
    var unit = dmac.Dmac.init(&bank);
    unit.memory = core;
    programCopy(&unit, 2);
    unit.write(at(dmac.off.dmsar), 4, source_at + 3);
    unit.write(at(dmac.off.dmamd), 2, 3 << xfer.field.sm_shift | 2 << xfer.field.dm_shift);
    unit.write(at(dmac.off.dmreq), 1, dmac.field.swreq | dmac.field.clrs);
    try std.testing.expectEqual(@as(u8, 0xA3), try byteAt(core, dest_at));
    try std.testing.expectEqual(@as(u8, 0xA2), try byteAt(core, dest_at + 1));
}

test "a fixed destination is written over and over, the way a FIFO is fed" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    try scene(core);
    const bank = startedBank();
    var unit = dmac.Dmac.init(&bank);
    unit.memory = core;
    programCopy(&unit, 3);
    unit.write(at(dmac.off.dmamd), 2, 2 << xfer.field.sm_shift);
    unit.write(at(dmac.off.dmreq), 1, dmac.field.swreq | dmac.field.clrs);
    try std.testing.expectEqual(@as(u8, 0xA2), try byteAt(core, dest_at));
    try std.testing.expectEqual(@as(u8, 0), try byteAt(core, dest_at + 1));
}

test "word units move four bytes at a time" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    try scene(core);
    const bank = startedBank();
    var unit = dmac.Dmac.init(&bank);
    unit.memory = core;
    programCopy(&unit, 2);
    unit.write(at(dmac.off.dmtmd), 2, 2 << xfer.field.sz_shift);
    unit.write(at(dmac.off.dmreq), 1, dmac.field.swreq);
    try std.testing.expectEqual(@as(u8, 0xA3), try byteAt(core, dest_at + 3));
    try std.testing.expectEqual(@as(u8, 0), try byteAt(core, dest_at + 4));
    try std.testing.expectEqual(@as(u64, 4), unit.channels[channel].bytes);
}

test "a repeat-mode channel is declined instead of approximated" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    try scene(core);
    const bank = startedBank();
    var unit = dmac.Dmac.init(&bank);
    unit.memory = core;
    programCopy(&unit, 4);
    unit.write(at(dmac.off.dmtmd), 2, 1 << xfer.field.md_shift);
    unit.write(at(dmac.off.dmreq), 1, dmac.field.swreq);
    try std.testing.expectEqual(@as(u8, 0), try byteAt(core, dest_at));
    try std.testing.expectEqual(
        xfer.Unsupported.repeat_mode,
        unit.last_refusal.?.unsupported,
    );
}

test "the transfer-end event is queued only when DMINT.DTIE is set" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    try scene(core);
    const bank = startedBank();
    var unit = dmac.Dmac.init(&bank);
    unit.memory = core;
    programCopy(&unit, 1);
    unit.write(at(dmac.off.dmreq), 1, dmac.field.swreq);
    try std.testing.expectEqual(@as(usize, 0), unit.dueEvents().len);

    unit.write(at(dmac.off.dmcra), 4, 1);
    unit.write(at(dmac.off.dmint), 1, dmac.field.dtie);
    unit.write(at(dmac.off.dmcnt), 1, dmac.field.dte);
    unit.write(at(dmac.off.dmreq), 1, dmac.field.swreq);
    const due = unit.dueEvents();
    try std.testing.expectEqual(@as(usize, 1), due.len);
    try std.testing.expectEqual(dmac.event_base, due.get(0));
}

test "DMSTS is write-0-to-clear, the same polarity the ICU uses" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    try scene(core);
    const bank = startedBank();
    var unit = dmac.Dmac.init(&bank);
    unit.memory = core;
    programCopy(&unit, 1);
    unit.write(at(dmac.off.dmreq), 1, dmac.field.swreq);
    try std.testing.expectEqual(@as(u32, dmac.field.dtif), unit.read(at(dmac.off.dmsts), 1));
    unit.write(at(dmac.off.dmsts), 1, 0);
    try std.testing.expectEqual(@as(u32, 0), unit.read(at(dmac.off.dmsts), 1));
}

test "a board with no memory behind it declines the request" {
    const bank = startedBank();
    var unit = dmac.Dmac.init(&bank);
    programCopy(&unit, 4);
    unit.write(at(dmac.off.dmreq), 1, dmac.field.swreq);
    try std.testing.expectEqual(dmac.Refusal.unbacked, unit.last_refusal.?);
}

test "each channel has its own window" {
    const bank = startedBank();
    var unit = dmac.Dmac.init(&bank);
    unit.write(dmac.channelAddress(3) + dmac.off.dmsar, 4, 0x1234_5678);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), unit.channels[3].dmsar);
    try std.testing.expectEqual(@as(u32, 0), unit.channels[0].dmsar);
    try std.testing.expectEqual(
        @as(u32, 0x1234_5678),
        unit.read(dmac.channelAddress(3) + dmac.off.dmsar, 4),
    );
}

test "a run that never touched the controller stays out of the report" {
    const bank = dma_bank.Bank.init();
    var unit = dmac.Dmac.init(&bank);
    try std.testing.expect(unit.quiet());
    unit.write(at(dmac.off.dmcnt), 1, dmac.field.dte);
    try std.testing.expect(!unit.quiet());
}

/// One past the last mapped byte of board RAM, so a copy aimed just below it
/// walks off the end partway through and memory refuses the rest.
const ram_edge: u32 = memmap.sram_end;

/// Channel 0 programmed for a block of `size` byte units aimed so only `fits`
/// of them have anywhere to go, armed and triggered once.
fn shortBlock(unit: *dmac.Dmac, size: u32, fits: u32) void {
    unit.write(at(dmac.off.dmsar), 4, source_at);
    unit.write(at(dmac.off.dmdar), 4, ram_edge - fits);
    unit.write(at(dmac.off.dmcra), 4, size << xfer.count.high_shift | size);
    unit.write(at(dmac.off.dmcrb), 4, 1);
    unit.write(at(dmac.off.dmtmd), 2, 2 << xfer.field.md_shift);
    unit.write(at(dmac.off.dmamd), 2, 2 << xfer.field.sm_shift | 2 << xfer.field.dm_shift);
    unit.write(at(dmac.off.dmcnt), 1, dmac.field.dte);
    unit.write(at(dmac.off.dmreq), 1, dmac.field.swreq);
}

test "a block memory cut short keeps the units that landed, addresses over them" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    try scene(core);
    try core.write(source_at, &@as([8]u8, @splat(0x11)));
    const bank = startedBank();
    var unit = dmac.Dmac.init(&bank);
    unit.memory = core;
    shortBlock(&unit, 8, 4);
    try std.testing.expectEqual(@as(u64, 4), unit.channels[channel].units);
    try std.testing.expectEqual(@as(u64, 4), unit.channels[channel].bytes);
    try std.testing.expectEqual(@as(u8, 0x11), try byteAt(core, ram_edge - 1));
    try std.testing.expectEqual(source_at + 4, unit.read(at(dmac.off.dmsar), 4));
    try std.testing.expectEqual(ram_edge, unit.read(at(dmac.off.dmdar), 4));
}

test "a block memory cut short neither ends the transfer nor pays its counts" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    try scene(core);
    const bank = startedBank();
    var unit = dmac.Dmac.init(&bank);
    unit.memory = core;
    shortBlock(&unit, 8, 4);
    const control = unit.read(at(dmac.off.dmcnt), 4);
    try std.testing.expect(control & dmac.field.dte != 0);
    try std.testing.expectEqual(@as(u32, 0), control >> 16 & dmac.field.dtif);
    try std.testing.expectEqual(@as(u32, 0), unit.channels[channel].completions);
    try std.testing.expectEqual(@as(u32, 8), unit.read(at(dmac.off.dmcra), 4) & xfer.count.low_mask);
    try std.testing.expectEqual(@as(u32, 1), unit.read(at(dmac.off.dmcrb), 4));
    try std.testing.expectEqual(@as(u32, 1), unit.channels[channel].faults);
}

test "a continuous request stops at the address memory refused" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    try scene(core);
    const bank = startedBank();
    var unit = dmac.Dmac.init(&bank);
    unit.memory = core;
    // Normal mode, 64 units, destination one byte short of the end of RAM:
    // the first unit lands, the second is refused, and the rest of the count
    // must not be walked into the same wall.
    unit.write(at(dmac.off.dmsar), 4, source_at);
    unit.write(at(dmac.off.dmdar), 4, ram_edge - 1);
    unit.write(at(dmac.off.dmcra), 4, 64);
    unit.write(at(dmac.off.dmtmd), 2, 0);
    unit.write(at(dmac.off.dmamd), 2, 2 << xfer.field.sm_shift | 2 << xfer.field.dm_shift);
    unit.write(at(dmac.off.dmcnt), 1, dmac.field.dte);
    unit.write(at(dmac.off.dmreq), 1, dmac.field.swreq | dmac.field.clrs);
    try std.testing.expectEqual(@as(u64, 1), unit.channels[channel].units);
    try std.testing.expectEqual(@as(u32, 63), unit.read(at(dmac.off.dmcra), 4) & xfer.count.low_mask);
    try std.testing.expect(unit.read(at(dmac.off.dmcnt), 4) & dmac.field.dte != 0);
}

test "a request nothing refuses still ends the transfer as it did" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    try scene(core);
    const bank = startedBank();
    var unit = dmac.Dmac.init(&bank);
    unit.memory = core;
    programCopy(&unit, 4);
    unit.write(at(dmac.off.dmreq), 1, dmac.field.swreq | dmac.field.clrs);
    try std.testing.expectEqual(@as(u64, 4), unit.channels[channel].units);
    try std.testing.expectEqual(@as(u32, 0), unit.channels[channel].faults);
    try std.testing.expectEqual(@as(u32, 1), unit.channels[channel].completions);
    try std.testing.expectEqual(@as(u32, 0), unit.read(at(dmac.off.dmcnt), 4) & dmac.field.dte);
}
