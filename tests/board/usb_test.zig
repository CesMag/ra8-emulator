//! Tests for src/board/usb.zig: the scripted host on the device jack and the
//! USBFS interrupt the board raises for it.
const std = @import("std");
const ra8 = @import("ra8");

const usb = ra8.board.usb;
const usbfs = ra8.chip.periph.usbfs;
const regs = ra8.chip.periph.usbhs_regs;

fn at(offset: u32) u32 {
    return usbfs.window.base + offset;
}

fn pulledUp() usb.Usb {
    var board = usb.Usb{};
    board.device.connectVbus();
    board.device.write(at(regs.reg.syscfg), 2, regs.syscfg.usbe | regs.syscfg.dprpu);
    board.device.write(at(regs.reg.intsts0), 2, ~@as(u32, usbfs.intsts0.dvst | usbfs.intsts0.vbint));
    return board;
}

test "no event while nothing is enabled" {
    var board = pulledUp();
    board.tick();
    board.tick();
    try std.testing.expectEqual(@as(usize, 0), board.dueEvents().len);
}

test "the host's first SETUP raises USBFS_INT once CTRE is enabled" {
    var board = pulledUp();
    board.device.write(at(regs.reg.intenb0), 2, usbfs.intsts0.ctrt);
    board.tick();
    board.tick();
    try std.testing.expectEqual(usbfs.host.Step.device_descriptor, board.script.step);
    const due = board.dueEvents();
    try std.testing.expectEqual(@as(usize, 1), due.len);
    try std.testing.expectEqual(usb.event.usbfs_int, due.get(0));
}

test "the line drops once the driver clears the cause" {
    var board = pulledUp();
    board.device.write(at(regs.reg.intenb0), 2, usbfs.intsts0.ctrt);
    board.tick();
    board.tick();
    board.device.write(at(regs.reg.intsts0), 2, ~@as(u32, usbfs.intsts0.ctrt));
    try std.testing.expectEqual(@as(usize, 0), board.dueEvents().len);
}

test "a disabled status bit raises nothing" {
    var board = pulledUp();
    board.device.write(at(regs.reg.intenb0), 2, usbfs.intsts0.vbint);
    board.tick();
    board.tick();
    try std.testing.expectEqual(@as(usize, 0), board.dueEvents().len);
}

test "loopBack cables the HS host to the board's own FS device" {
    var board = pulledUp();
    try std.testing.expect(board.cable == null);
    board.loopBack();
    const far = board.host.xfer.far orelse return error.NoCable;
    try std.testing.expectEqual(&board.device, board.cable.?.device);
    try std.testing.expectEqual(@as(*anyopaque, &board.cable.?), far.context);
}

test "with the cable in, the scripted host stays off the device jack" {
    var cabled = pulledUp();
    cabled.loopBack();
    var scripted = pulledUp();
    var step: u32 = 0;
    while (step < 64) : (step += 1) {
        cabled.tick();
        scripted.tick();
    }
    try std.testing.expectEqualDeep(usbfs.host.Host{}, cabled.script);
    try std.testing.expect(!std.meta.eql(usbfs.host.Host{}, scripted.script));
}
