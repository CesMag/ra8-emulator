//! Covers src/chip/core/cpu/counted_trip.zig: a bounded poll's trips, counted once
//! its values move by the same amount every trip (RA8EMU-602).
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("../exception/ram.zig");
const Regs = ra8.chip.core.cpu.regs.Regs;
const ct = ra8.chip.core.cpu.cpu.counted.trip;

const head: u32 = fixture.code;
const frame: u32 = fixture.base + 0x200;
const limit: u32 = 999_999;

fn atHead() Regs {
    var regs = Regs{};
    regs.pc = head;
    regs.msp = fixture.msp_top;
    regs.xpsr = 0x0100_0000;
    regs.low[7] = frame;
    return regs;
}

/// adds r0,#1 ; cmp r0,r1 ; bls loop, with R1 the limit.
fn upTrip(rec: *ct.Recorder, regs: *Regs, step: u32) void {
    rec.step(regs, 0x3001, 0);
    regs.low[0] +%= step;
    rec.step(regs, 0x4288, 0);
    rec.step(regs, 0xD9FC, 0);
}

test "two trips that move the same way count the rest up to the limit" {
    var rec = ct.Recorder{};
    var regs = atHead();
    regs.low[0] = 10;
    regs.low[1] = 100;
    rec.start(&regs);
    var ram = fixture.Ram{};
    upTrip(&rec, &regs, 1);
    try std.testing.expectEqual(ct.Outcome.again, rec.atHead(&regs, ram.view()));
    upTrip(&rec, &regs, 1);
    // The second trip compared 12 with 100; 99 is 87 trips off.
    try std.testing.expectEqual(ct.Outcome{ .retire = 86 }, rec.atHead(&regs, ram.view()));
    try rec.apply(&regs, ram.view(), 86);
    try std.testing.expectEqual(@as(u32, 98), regs.low[0]);
    try std.testing.expectEqual(@as(u32, 100), regs.low[1]);
}

/// The counter shape of internal_ns_ipc_recv: a word on the stack frame.
fn wordTrip(rec: *ct.Recorder, regs: *Regs, ram: *fixture.Ram) void {
    const at = frame + 20;
    rec.step(regs, 0x697B, 0); // ldr r3,[r7,#20]
    regs.low[3] = ram.word(at);
    rec.step(regs, 0x3301, 0); // adds r3,#1
    regs.low[3] +%= 1;
    rec.step(regs, 0x617B, 0); // str r3,[r7,#20]
    rec.store(at, ram.word(at));
    ram.putWord(at, regs.low[3]);
    rec.step(regs, 0x697B, 0); // ldr r3,[r7,#20]
    rec.step(regs, 0x4A03, 0); // ldr r2,[pc,#12]
    regs.low[2] = limit;
    rec.step(regs, 0x4293, 0); // cmp r3,r2
    rec.step(regs, 0xD9E4, 0); // bls loop
}

test "a counter kept in a RAM word moves on with the registers" {
    var ram = fixture.Ram{};
    ram.putWord(frame + 20, 41);
    var rec = ct.Recorder{};
    var regs = atHead();
    regs.low[3] = 41;
    regs.low[2] = limit;
    rec.start(&regs);
    wordTrip(&rec, &regs, &ram);
    try std.testing.expectEqual(ct.Outcome.again, rec.atHead(&regs, ram.view()));
    wordTrip(&rec, &regs, &ram);
    const got = rec.atHead(&regs, ram.view());
    try std.testing.expectEqual(ct.Outcome{ .retire = 999_998 - 43 - 1 }, got);
    try rec.apply(&regs, ram.view(), 10);
    try std.testing.expectEqual(@as(u32, 53), regs.low[3]);
    try std.testing.expectEqual(@as(u32, 53), ram.word(frame + 20));
}

test "a trip that moves differently, a changed xPSR or a long trip is refused" {
    var ram = fixture.Ram{};
    var rec = ct.Recorder{};
    var regs = atHead();
    regs.low[1] = 100;
    rec.start(&regs);
    upTrip(&rec, &regs, 1);
    try std.testing.expectEqual(ct.Outcome.again, rec.atHead(&regs, ram.view()));
    upTrip(&rec, &regs, 2);
    try std.testing.expectEqual(ct.Outcome.refuse, rec.atHead(&regs, ram.view()));

    regs = atHead();
    rec.start(&regs);
    upTrip(&rec, &regs, 1);
    regs.xpsr |= 0x4000_0000;
    try std.testing.expectEqual(ct.Outcome.refuse, rec.atHead(&regs, ram.view()));

    regs = atHead();
    rec.start(&regs);
    for (0..ct.max_steps + 1) |_| rec.step(&regs, 0xBF00, 0);
    try std.testing.expectEqual(ct.Outcome.refuse, rec.atHead(&regs, ram.view()));
}

test "a word that only starts changing on the second trip is refused" {
    var ram = fixture.Ram{};
    var rec = ct.Recorder{};
    var regs = atHead();
    rec.start(&regs);
    rec.step(&regs, 0xBF00, 0);
    try std.testing.expectEqual(ct.Outcome.again, rec.atHead(&regs, ram.view()));
    rec.step(&regs, 0x617B, 0);
    rec.store(frame + 20, 0);
    ram.putWord(frame + 20, 7);
    try std.testing.expectEqual(ct.Outcome.refuse, rec.atHead(&regs, ram.view()));
}
