//! CFDRFCCa: when RFE takes, when it does not, and what the register says
//! about the FIFO once it has.
const std = @import("std");
const ra8 = @import("ra8");
const rx_config = ra8.chip.periph.canfd.rx.config;

const depth_4: u32 = 1 << 8;

test "a fresh register has no FIFO and nothing refused" {
    const cfg = rx_config.Config{};
    try std.testing.expect(!cfg.enabled());
    try std.testing.expect(!cfg.sized());
    try std.testing.expect(cfg.quiet());
}

test "RFE takes out of reset once a depth is programmed" {
    var cfg = rx_config.Config{};
    cfg.store(depth_4, true);
    cfg.store(depth_4 | rx_config.field.rfe, false);
    try std.testing.expect(cfg.enabled());
    try std.testing.expectEqual(@as(u32, 0), cfg.refused);
}

test "RFE does not take in GL_RESET" {
    // ra8_canfd.c splits its two writes precisely because of this: setting
    // RFE in GL_RESET silently no-ops on silicon.
    var cfg = rx_config.Config{};
    cfg.store(depth_4 | rx_config.field.rfe, true);
    try std.testing.expect(!cfg.enabled());
    try std.testing.expectEqual(@as(u32, 1), cfg.refused);
    // The rest of the store still landed.
    try std.testing.expect(cfg.sized());
}

test "RFE does not take while RFDC is zero" {
    var cfg = rx_config.Config{};
    cfg.store(rx_config.field.rfe, false);
    try std.testing.expect(!cfg.enabled());
    try std.testing.expectEqual(@as(u32, 1), cfg.refused);
}

test "the depth write then the enable write is the sequence that works" {
    var cfg = rx_config.Config{};
    cfg.store(depth_4 | (7 << 4), true);
    try std.testing.expect(!cfg.enabled());
    cfg.store(cfg.word | rx_config.field.rfe, false);
    try std.testing.expect(cfg.enabled());
    try std.testing.expectEqual(@as(u32, 0), cfg.refused);
}

test "clearing RFE is allowed from anywhere" {
    var cfg = rx_config.Config{};
    cfg.store(depth_4, false);
    cfg.store(depth_4 | rx_config.field.rfe, false);
    try std.testing.expect(cfg.enabled());
    cfg.store(depth_4, true);
    try std.testing.expect(!cfg.enabled());
    try std.testing.expectEqual(@as(u32, 0), cfg.refused);
}

test "a store that only repeats a standing RFE is not a refusal" {
    var cfg = rx_config.Config{};
    cfg.store(depth_4, false);
    cfg.store(depth_4 | rx_config.field.rfe, false);
    cfg.store(depth_4 | rx_config.field.rfe, true);
    try std.testing.expect(cfg.enabled());
    try std.testing.expectEqual(@as(u32, 0), cfg.refused);
}

test "RFIE is read back and decides nothing here" {
    var cfg = rx_config.Config{};
    cfg.store(depth_4 | rx_config.field.rfie, true);
    try std.testing.expect(cfg.interrupting());
    try std.testing.expect(!cfg.enabled());
}

test "the fields sit where ra8_canfd_regs.h puts them" {
    try std.testing.expectEqual(@as(u32, 0x03C), rx_config.off_rfcc0);
    try std.testing.expectEqual(@as(u32, 1), rx_config.field.rfe);
    try std.testing.expectEqual(@as(u32, 2), rx_config.field.rfie);
    try std.testing.expectEqual(@as(u32, 0x0000_0700), rx_config.field.rfdc);
}
