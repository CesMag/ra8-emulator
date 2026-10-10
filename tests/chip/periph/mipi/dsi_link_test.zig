//! The MIPI DSI link status rule.
const std = @import("std");
const ra8 = @import("ra8");

const rule = ra8.chip.periph.mipi.dsi_link;

test "an idle link reports nothing running" {
    try std.testing.expectEqual(@as(u32, 0), rule.linkWord(false, false, false, .{}));
}

test "video mode running shows up as VRUN, which is what refuses an LP command" {
    const word = rule.linkWord(false, false, true, .{});
    try std.testing.expect(word & rule.link.vrun != 0);
    try std.testing.expect(word & rule.link.sq0run == 0);
    try std.testing.expect(word & rule.link.sq1run == 0);
}

test "a running HS clock is HSBUSY and nothing else" {
    const word = rule.linkWord(false, false, false, .{ .hs_clock = true });
    try std.testing.expectEqual(rule.link.hsbusy, word);
}

test "each sequence channel reports on its own bit" {
    try std.testing.expectEqual(rule.link.sq0run, rule.linkWord(true, false, false, .{}));
    try std.testing.expectEqual(rule.link.sq1run, rule.linkWord(false, true, false, .{}));
}

test "a parked link stops both lanes and keeps UlpsActiveNot high" {
    const word = rule.phyWord(.{}, 0);
    try std.testing.expect(word & rule.phy.clstp != 0);
    try std.testing.expect(word & rule.phy.dl0stp != 0);
    try std.testing.expect(word & rule.phy.dl1stp != 0);
    try std.testing.expect(word & rule.phy.cluan != 0);
    try std.testing.expect(word & rule.phy.dl0uan != 0);
}

test "the clock lane stops being stopped once HS is running" {
    const word = rule.phyWord(.{ .hs_clock = true }, 0);
    try std.testing.expect(word & rule.phy.clstp == 0);
    try std.testing.expect(word & rule.phy.dl0stp == 0);
}

test "ULPS takes UlpsActiveNot down on the lane that entered it" {
    const clock = rule.phyWord(.{ .clock_ulps = true }, 0);
    try std.testing.expect(clock & rule.phy.cluan == 0);
    try std.testing.expect(clock & rule.phy.dl0uan != 0);
    const data = rule.phyWord(.{ .data_ulps = true }, 0);
    try std.testing.expect(data & rule.phy.dl0uan == 0);
    try std.testing.expect(data & rule.phy.dl1uan == 0);
    try std.testing.expect(data & rule.phy.cluan != 0);
}

test "only the event bits ride through from the latch" {
    const word = rule.phyWord(.{}, rule.phy.cllp2hs | rule.phy.dl0stp);
    try std.testing.expect(word & rule.phy.cllp2hs != 0);
    // dl0stp is a level, so the latch cannot force it; here it is up anyway
    // because the lane really is stopped.
    try std.testing.expect(word & rule.phy.dl0stp != 0);
    try std.testing.expect(rule.phyWord(.{ .hs_clock = true }, rule.phy.dl0stp) & rule.phy.dl0stp == 0);
}

test "video mode reports RUNNING as a level and VIRDY as a latch" {
    try std.testing.expectEqual(@as(u32, 0), rule.videoWord(false, 0));
    try std.testing.expectEqual(rule.video.running, rule.videoWord(true, 0));
    const started = rule.videoWord(true, rule.video.virdy);
    try std.testing.expect(started & rule.video.virdy != 0);
    try std.testing.expect(started & rule.video.running != 0);
    const stopped = rule.videoWord(false, rule.video.stop);
    try std.testing.expect(stopped & rule.video.stop != 0);
    try std.testing.expect(stopped & rule.video.running == 0);
}

test "a held software reset holds every subsystem" {
    try std.testing.expectEqual(rule.reset_status.all_reset, rule.resetWord(true, .{}));
    try std.testing.expectEqual(rule.reset_status.all_reset, rule.resetWord(true, .{ .hs_clock = true }));
}

test "out of reset the lanes report stopped until the clock runs" {
    const idle = rule.resetWord(false, .{});
    try std.testing.expect(idle & rule.reset_status.dl0stp != 0);
    try std.testing.expect(idle & rule.reset_status.rsths == 0);
    try std.testing.expectEqual(@as(u32, 0), rule.resetWord(false, .{ .hs_clock = true }));
}

test "a finished sequence reports both finish flags and not RUNNING" {
    try std.testing.expect(rule.sequence.finished & rule.sequence.aactfin != 0);
    try std.testing.expect(rule.sequence.finished & rule.sequence.adesfin != 0);
    try std.testing.expect(rule.sequence.finished & rule.sequence.running == 0);
}

test "the control-word decoders read the bits the driver writes" {
    try std.testing.expect(rule.startRequested(rule.video_control.vstart));
    try std.testing.expect(!rule.startRequested(rule.video_control.vstop));
    try std.testing.expect(rule.stopRequested(rule.video_control.vstop));
    try std.testing.expect(rule.clockRunning(rule.hs_clock.start));
    try std.testing.expect(!rule.clockRunning(rule.hs_clock.continuous));
    try std.testing.expect(rule.continuousClock(rule.hs_clock.start | rule.hs_clock.continuous));
    try std.testing.expect(rule.sequenceStarted(rule.sequence.start | rule.sequence.chsel));
    try std.testing.expect(!rule.sequenceStarted(rule.sequence.chsel));
    try std.testing.expect(rule.inReset(rule.reset_control.swrst));
    try std.testing.expect(!rule.inReset(rule.reset_control.ftxstp));
}
