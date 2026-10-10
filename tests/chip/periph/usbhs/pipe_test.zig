//! The pipe table: which pipe the window is open on, and what a pipe will
//! accept.
const std = @import("std");
const ra8 = @import("ra8");
const regs = ra8.chip.periph.usbhs.regs;
const usbhs_pipe = ra8.chip.periph.usbhs.pipe;

test "PIPESEL opens the window on the pipe it names" {
    var table = usbhs_pipe.Table{};
    table.select(3);
    try std.testing.expect(table.current() != null);
    try std.testing.expectEqual(@as(u16, 3), table.selected);
}

test "a pipe the part does not have selects nothing" {
    var table = usbhs_pipe.Table{};
    table.select(regs.pipe.count);
    try std.testing.expect(table.current() == null);
    try std.testing.expectEqual(@as(u32, 1), table.bad_pipe);
}

test "a config meant for a pipe out of range does not land on the DCP" {
    var table = usbhs_pipe.Table{};
    table.select(12);
    try std.testing.expect(!table.configure(5));
    try std.testing.expectEqual(@as(u8, 0), table.pipes[0].endpoint);
}

test "PIPESEL zero is no window, not the control pipe" {
    var table = usbhs_pipe.Table{};
    try std.testing.expect(!table.configure(2));
    try std.testing.expectEqual(@as(u32, 1), table.dcp_config);
    try std.testing.expectEqual(@as(u8, 0), table.pipes[0].endpoint);
}

test "a configured pipe reads back its endpoint and direction" {
    var table = usbhs_pipe.Table{};
    table.select(1);
    try std.testing.expect(table.configure(regs.pipe.dir_transmit | 2));
    try std.testing.expectEqual(@as(u8, 2), table.pipes[1].endpoint);
    try std.testing.expect(!table.pipes[1].in);
    try std.testing.expectEqual(regs.pipe.dir_transmit | 2, table.config());
}

test "a host pipe with DIR clear receives" {
    var table = usbhs_pipe.Table{};
    table.select(1);
    try std.testing.expect(table.configure(1));
    try std.testing.expect(table.pipes[1].in);
    try std.testing.expectEqual(@as(u16, 1), table.config());
}

test "a packet size past what the bus carries is refused" {
    var table = usbhs_pipe.Table{};
    table.select(1);
    try std.testing.expect(!table.setMaxPacket(1024));
    try std.testing.expectEqual(@as(u16, 0), table.maxPacket());
    try std.testing.expectEqual(@as(u32, 1), table.too_big);
}

test "a zero packet size is refused too" {
    var table = usbhs_pipe.Table{};
    table.select(2);
    try std.testing.expect(!table.setMaxPacket(0));
    try std.testing.expectEqual(@as(u32, 1), table.too_big);
}

test "the largest legal packet is accepted" {
    var table = usbhs_pipe.Table{};
    table.select(2);
    try std.testing.expect(table.setMaxPacket(regs.pipe.maxp_limit));
    try std.testing.expectEqual(regs.pipe.maxp_limit, table.maxPacket());
}

test "a closed window reads zero rather than the control pipe's config" {
    var table = usbhs_pipe.Table{};
    table.select(1);
    _ = table.configure(7);
    table.select(0);
    try std.testing.expectEqual(@as(u16, 0), table.config());
    try std.testing.expectEqual(@as(u16, 0), table.maxPacket());
}

test "PIPECTR addresses its own pipe" {
    var table = usbhs_pipe.Table{};
    try std.testing.expect(table.setControl(4, regs.pipe.pid_buf));
    try std.testing.expectEqual(regs.pipe.pid_buf, table.control(4));
    try std.testing.expect(table.pipes[4].armed());
}

test "PIPECTR never names the control pipe" {
    var table = usbhs_pipe.Table{};
    try std.testing.expect(!table.setControl(0, regs.pipe.pid_buf));
    try std.testing.expectEqual(@as(u32, 1), table.bad_pipe);
}

test "PIPECTR past the table is refused, not wrapped" {
    var table = usbhs_pipe.Table{};
    try std.testing.expect(!table.setControl(regs.pipe.count, regs.pipe.pid_buf));
    try std.testing.expectEqual(@as(u16, 0), table.control(regs.pipe.count + 1));
    try std.testing.expectEqual(@as(u32, 2), table.bad_pipe);
}

test "a pipe is armed only on BUF" {
    var table = usbhs_pipe.Table{};
    _ = table.setControl(1, regs.pipe.pid_nak);
    try std.testing.expect(!table.pipes[1].armed());
    _ = table.setControl(1, regs.pipe.pid_stall);
    try std.testing.expect(!table.pipes[1].armed());
}

test "an untouched table is quiet" {
    var table = usbhs_pipe.Table{};
    try std.testing.expect(table.quiet());
    table.select(1);
    _ = table.setMaxPacket(64);
    try std.testing.expect(!table.quiet());
}
