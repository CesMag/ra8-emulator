//! RA8EMU-662: the timer units saved with non-default state and loaded
//! into fresh units compare equal.
const std = @import("std");
const ra8 = @import("ra8");
const periph = ra8.chip.periph;
const file = ra8.snapshot.file;
const timers = ra8.chip.snapshot.timers;

/// The Board's timer fields, under the Board's names.
const Stand = struct {
    clock: periph.rtc.Rtc = .{},
    interval: periph.agt.Agt = .{},
    pwm: periph.gpt.Gpt = .{},
    pwm_delay: periph.gpt.pdg.Pdg = .{},
    ptp: periph.gptp.Gptp = .{},
    watchdog: periph.wdt.Wdt = .{},
    heartbeat: periph.iwdt.Iwdt = .{},
};

fn busy() Stand {
    var board: Stand = .{};
    board.clock.seconds = 3_600;
    board.clock.reg[4] = 0x59;
    board.clock.due_alarm = true;
    board.interval.channels[3].counter = 0x1234;
    board.interval.channels[3].underflows = 8;
    board.interval.pending = 0b1000;
    board.pwm.channels[2].cnt = 0xABCD;
    board.pwm.pending = true;
    board.pwm_delay.gtdlycr = 0x11;
    board.pwm_delay.codes[1][0][1] = 0x2F;
    board.ptp.starts = 4;
    board.ptp.ns_remainder = 17;
    board.watchdog.armed = true;
    board.watchdog.counter = 0x3FFF;
    board.heartbeat.option_word = 0xFFFF_FFFE;
    board.heartbeat.counter = 0x123;
    return board;
}

test "every timer unit round-trips" {
    const board = busy();
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try file.writeHeader(&list.writer);
    try timers.save(&board, &list.writer);
    var fresh: Stand = .{};
    try timers.load(&fresh, list.written());
    try std.testing.expectEqualDeep(board, fresh);
}

test "a file without a timers section is Missing and nothing changes" {
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try file.writeHeader(&list.writer);
    var fresh: Stand = .{};
    fresh.watchdog.counter = 9;
    try std.testing.expectError(error.Missing, timers.load(&fresh, list.written()));
    try std.testing.expectEqual(@as(u32, 9), fresh.watchdog.counter);
}
