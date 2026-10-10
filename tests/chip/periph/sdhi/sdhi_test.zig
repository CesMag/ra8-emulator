//! Covers src/chip/periph/sdhi/sdhi.zig.
const std = @import("std");
const ra8 = @import("ra8");
const sdhi = ra8.chip.periph.sdhi;
const card = ra8.components.sd_bus_card;
const bus_line = ra8.components.sd_bus_line;

/// A controller with a card in its slot. Kept in place: the slot holds a
/// pointer to the card.
const Stand = struct {
    host: sdhi.Sdhi,
    disk: card.Card,

    fn init(self: *Stand) void {
        self.* = .{ .host = sdhi.Sdhi.init(), .disk = card.Card.init(std.testing.allocator) };
        self.host.card = bus_line.line(&self.disk);
    }

    fn deinit(self: *Stand) void {
        self.disk.deinit();
    }
};

fn poke(host: *sdhi.Sdhi, offset: u32, value: u32) void {
    host.write(sdhi.address(offset), 4, value);
}

fn peek(host: *sdhi.Sdhi, offset: u32) u32 {
    return host.read(sdhi.address(offset), 4);
}

/// Issue one command the way the driver does: the argument first, then the
/// command word.
fn command(host: *sdhi.Sdhi, index: u32, arg: u32) void {
    poke(host, sdhi.off.sd_arg, arg);
    poke(host, sdhi.off.sd_cmd, index);
}

/// The identification sequence an image runs before any block command.
fn identify(host: *sdhi.Sdhi) void {
    command(host, sdhi.cmd.go_idle, 0);
    command(host, sdhi.cmd.if_cond, 0x1AA);
    command(host, sdhi.cmd.app_cmd, 0);
    command(host, sdhi.cmd.op_cond, 0x4030_0000);
    command(host, sdhi.cmd.send_cid, 0);
    command(host, sdhi.cmd.send_rca, 0);
    command(host, sdhi.cmd.select, card.response.rca_value);
}

test "a fresh controller is quiet and out of reset" {
    var stand: Stand = undefined;
    stand.init();
    defer stand.deinit();
    const host = &stand.host;
    try std.testing.expect(host.quiet());
    try std.testing.expectEqual(sdhi.soft_rst.release, peek(host, sdhi.off.soft_rst));
    try std.testing.expectEqual(@as(u32, 4), host.lanes());
}

test "a command raises RSPEND so the driver's poll exits" {
    var stand: Stand = undefined;
    stand.init();
    defer stand.deinit();
    const host = &stand.host;
    command(host, sdhi.cmd.if_cond, 0x1AA);
    try std.testing.expectEqual(sdhi.status.rspend, peek(host, sdhi.off.sd_info1) & sdhi.status.rspend);
    try std.testing.expectEqual(card.response.r7_if_cond, peek(host, sdhi.off.sd_rsp10));
}

test "ACMD41 needs its CMD55 prefix" {
    var stand: Stand = undefined;
    stand.init();
    defer stand.deinit();
    const host = &stand.host;
    command(host, sdhi.cmd.op_cond, 0);
    try std.testing.expect(peek(host, sdhi.off.sd_rsp10) != card.response.ocr_ready);
    command(host, sdhi.cmd.app_cmd, 0);
    command(host, sdhi.cmd.op_cond, 0);
    try std.testing.expectEqual(card.response.ocr_ready, peek(host, sdhi.off.sd_rsp10));
}

test "CMD9 answers with the card's own capacity" {
    var stand: Stand = undefined;
    stand.init();
    defer stand.deinit();
    const host = &stand.host;
    identify(host);
    command(host, sdhi.cmd.send_csd, 0);
    const c_size = (card.geometry.capacity_blocks / card.geometry.csize_unit) - 1;
    try std.testing.expectEqual(card.response.csd_v2, peek(host, sdhi.off.sd_rsp76));
    try std.testing.expectEqual((c_size & 0xFFFF) << 16, peek(host, sdhi.off.sd_rsp32));
}

test "a read from an unselected card is refused, not served" {
    var stand: Stand = undefined;
    stand.init();
    defer stand.deinit();
    const host = &stand.host;
    command(host, sdhi.cmd.read_single, 0);
    try std.testing.expectEqual(@as(u32, 1), host.out_of_state);
    try std.testing.expectEqual(
        card.response.r1_illegal,
        peek(host, sdhi.off.sd_rsp10) & card.response.r1_illegal,
    );
    try std.testing.expectEqual(@as(u32, 0), peek(host, sdhi.off.sd_info2) & sdhi.status.bre);
    _ = peek(host, sdhi.off.sd_buf0);
    try std.testing.expectEqual(@as(u32, 1), host.starved);
}

test "a selected card serves a block and drops BRE when it is drained" {
    var stand: Stand = undefined;
    stand.init();
    defer stand.deinit();
    const host = &stand.host;
    identify(host);
    command(host, sdhi.cmd.read_single, 6);
    try std.testing.expectEqual(sdhi.status.bre, peek(host, sdhi.off.sd_info2) & sdhi.status.bre);
    for (0..128) |_| _ = peek(host, sdhi.off.sd_buf0);
    try std.testing.expectEqual(@as(u32, 1), host.reads);
    try std.testing.expectEqual(@as(u32, 0), peek(host, sdhi.off.sd_info2) & sdhi.status.bre);
}

test "a block written through the FIFO reads back" {
    var stand: Stand = undefined;
    stand.init();
    defer stand.deinit();
    const host = &stand.host;
    identify(host);
    command(host, sdhi.cmd.write_single, 11);
    try std.testing.expectEqual(sdhi.status.bwe, peek(host, sdhi.off.sd_info2) & sdhi.status.bwe);
    for (0..128) |i| poke(host, sdhi.off.sd_buf0, @intCast(i + 1));
    try std.testing.expectEqual(@as(u32, 1), host.writes);
    try std.testing.expectEqual(@as(u32, 1), host.card.held());
    command(host, sdhi.cmd.read_single, 11);
    for (0..128) |i| {
        try std.testing.expectEqual(@as(u32, @intCast(i + 1)), peek(host, sdhi.off.sd_buf0));
    }
}

test "a multi block read walks the addresses and keeps BRE up" {
    var stand: Stand = undefined;
    stand.init();
    defer stand.deinit();
    const host = &stand.host;
    identify(host);
    poke(host, sdhi.off.sd_seccnt, 3);
    command(host, sdhi.cmd.read_multi, 20);
    for (0..128) |_| _ = peek(host, sdhi.off.sd_buf0);
    try std.testing.expectEqual(@as(u32, 21), host.data.lba);
    try std.testing.expectEqual(sdhi.status.bre, peek(host, sdhi.off.sd_info2) & sdhi.status.bre);
    for (0..256) |_| _ = peek(host, sdhi.off.sd_buf0);
    try std.testing.expectEqual(@as(u32, 3), host.reads);
    try std.testing.expectEqual(@as(u32, 0), peek(host, sdhi.off.sd_info2) & sdhi.status.bre);
}

test "CMD12 ends a transfer that is still running" {
    var stand: Stand = undefined;
    stand.init();
    defer stand.deinit();
    const host = &stand.host;
    identify(host);
    poke(host, sdhi.off.sd_seccnt, 4);
    command(host, sdhi.cmd.read_multi, 0);
    command(host, sdhi.cmd.stop, 0);
    try std.testing.expectEqual(@as(u32, 0), peek(host, sdhi.off.sd_info2) & sdhi.status.bre);
    _ = peek(host, sdhi.off.sd_buf0);
    try std.testing.expectEqual(@as(u32, 1), host.starved);
}

test "firmware cannot write its own response" {
    var stand: Stand = undefined;
    stand.init();
    defer stand.deinit();
    const host = &stand.host;
    poke(host, sdhi.off.sd_rsp10, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u32, 0), peek(host, sdhi.off.sd_rsp10));
    try std.testing.expectEqual(@as(u32, 1), host.faked);
}

test "a status store acknowledges a flag and cannot raise one" {
    var stand: Stand = undefined;
    stand.init();
    defer stand.deinit();
    const host = &stand.host;
    command(host, sdhi.cmd.if_cond, 0);
    poke(host, sdhi.off.sd_info1, ~sdhi.status.rspend);
    try std.testing.expectEqual(@as(u32, 0), peek(host, sdhi.off.sd_info1) & sdhi.status.rspend);
    poke(host, sdhi.off.sd_info2, sdhi.status.bre | sdhi.status.bwe);
    try std.testing.expectEqual(@as(u32, 0), peek(host, sdhi.off.sd_info2));
    poke(host, sdhi.off.sd_info1, sdhi.status.rspend);
    try std.testing.expectEqual(@as(u32, 0), peek(host, sdhi.off.sd_info1) & sdhi.status.rspend);
}

test "a command issued while SOFT_RST is asserted does nothing" {
    var stand: Stand = undefined;
    stand.init();
    defer stand.deinit();
    const host = &stand.host;
    identify(host);
    poke(host, sdhi.off.soft_rst, 0);
    command(host, sdhi.cmd.read_single, 0);
    try std.testing.expectEqual(@as(u32, 1), host.while_reset);
    try std.testing.expectEqual(@as(u32, 0), peek(host, sdhi.off.sd_info1) & sdhi.status.rspend);
    poke(host, sdhi.off.soft_rst, sdhi.soft_rst.release);
    command(host, sdhi.cmd.if_cond, 0);
    try std.testing.expectEqual(sdhi.status.rspend, peek(host, sdhi.off.sd_info1) & sdhi.status.rspend);
}

test "the reset sequence clears a transfer in flight" {
    var stand: Stand = undefined;
    stand.init();
    defer stand.deinit();
    const host = &stand.host;
    identify(host);
    command(host, sdhi.cmd.read_single, 2);
    poke(host, sdhi.off.soft_rst, 0);
    poke(host, sdhi.off.soft_rst, sdhi.soft_rst.release);
    try std.testing.expectEqual(@as(u32, 0), peek(host, sdhi.off.sd_info2));
    _ = peek(host, sdhi.off.sd_buf0);
    try std.testing.expectEqual(@as(u32, 1), host.starved);
}

test "a narrow FIFO access is refused rather than eating a word" {
    var stand: Stand = undefined;
    stand.init();
    defer stand.deinit();
    const host = &stand.host;
    identify(host);
    command(host, sdhi.cmd.read_single, 0);
    try std.testing.expectEqual(@as(u32, 0), host.read(sdhi.address(sdhi.off.sd_buf0), 1));
    host.write(sdhi.address(sdhi.off.sd_buf0), 2, 0x1234);
    try std.testing.expectEqual(@as(u32, 2), host.narrow);
    try std.testing.expectEqual(@as(u32, 0), host.data.word_idx);
}

test "a halfword store to SD_CMD leaves the bytes above it alone" {
    var stand: Stand = undefined;
    stand.init();
    defer stand.deinit();
    const host = &stand.host;
    poke(host, sdhi.off.sd_cmd, 0xFFFF_0000);
    host.write(sdhi.address(sdhi.off.sd_cmd), 2, sdhi.cmd.if_cond);
    try std.testing.expectEqual(@as(u32, 0xFFFF_0008), peek(host, sdhi.off.sd_cmd));
}

test "SD_OPTION decodes the bus width" {
    var stand: Stand = undefined;
    stand.init();
    defer stand.deinit();
    const host = &stand.host;
    poke(host, sdhi.off.sd_option, sdhi.option.width_1bit);
    try std.testing.expectEqual(@as(u32, 1), host.lanes());
    poke(host, sdhi.off.sd_option, sdhi.option.width_8bit);
    try std.testing.expectEqual(@as(u32, 8), host.lanes());
    poke(host, sdhi.off.sd_option, 0);
    try std.testing.expectEqual(@as(u32, 4), host.lanes());
}

test "an unmodelled register keeps what was written" {
    var stand: Stand = undefined;
    stand.init();
    defer stand.deinit();
    const host = &stand.host;
    poke(host, sdhi.off.sd_stop, 0x0000_0101);
    try std.testing.expectEqual(@as(u32, 0x0000_0101), peek(host, sdhi.off.sd_stop));
}
