//! Covers src/interfaces/usbip/usbip_session.zig: commands read off a
//! byte stream, URBs finishing as the firmware serves them, and unlinks.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const usbfs = ra8.chip.periph.usbfs;
const pipe = usbfs.pipe;
const regs = ra8.chip.periph.usbhs_regs;
const session = cli_app.cli.usbip_export.session;
const wire = cli_app.cli.usbip_wire;

fn at(offset: u32) u32 {
    return usbfs.window.base + offset;
}

fn open(device: *usbfs.Device, n: u16, endpoint: u16, in: bool) void {
    const dir: u16 = if (in) pipe.cfg.dir_in else 0;
    device.write(at(regs.reg.pipesel), 2, n);
    device.write(at(regs.reg.pipecfg), 2, (1 << pipe.cfg.kind_shift) | dir | endpoint);
    device.write(at(regs.reg.pipemaxp), 2, 64);
    device.write(at(regs.reg.pipesel), 2, 0);
}

fn put(bytes: []u8, at_: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at_..][0..4], value, .big);
}

fn submit(seqnum: u32, in: bool, ep: u32, length: u32) [wire.basic_len]u8 {
    var bytes = @as([wire.basic_len]u8, @splat(0));
    put(&bytes, 0, wire.cmd.submit);
    put(&bytes, 4, seqnum);
    put(&bytes, 12, @intFromBool(in));
    put(&bytes, 16, ep);
    put(&bytes, 24, length);
    return bytes;
}

fn unlink(seqnum: u32, victim: u32) [wire.basic_len]u8 {
    var bytes = @as([wire.basic_len]u8, @splat(0));
    put(&bytes, 0, wire.cmd.unlink);
    put(&bytes, 4, seqnum);
    put(&bytes, 20, victim);
    return bytes;
}

fn word(bytes: []const u8, at_: usize) u32 {
    return std.mem.readInt(u32, bytes[at_..][0..4], .big);
}

fn commit(device: *usbfs.Device, n: u16) void {
    device.write(at(regs.reg.cfifosel), 2, n);
    device.write(at(regs.reg.cfifo), 2, 0x6968);
    device.write(at(regs.reg.cfifoctr), 2, regs.fifo.bval);
}

test "an OUT URB and its payload come off the stream and finish on the next pump" {
    const live = try std.testing.allocator.create(session.Session);
    defer std.testing.allocator.destroy(live);
    live.* = .{};
    var device = usbfs.Device{};
    open(&device, 1, 2, false);
    var input: [wire.basic_len + 3]u8 = undefined;
    input[0..wire.basic_len].* = submit(5, false, 2, 3);
    @memcpy(input[wire.basic_len..], "abc");
    var stream: std.Io.Reader = .fixed(&input);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expect(try live.receive(&stream, &out.writer));
    try std.testing.expectEqual(@as(usize, 1), live.pending());
    try std.testing.expectEqual(@as(usize, 1), try live.pump(&device, &out.writer));
    try std.testing.expectEqual(@as(usize, wire.basic_len), out.written().len);
    try std.testing.expectEqual(wire.cmd.ret_submit, word(out.written(), 0));
    try std.testing.expectEqual(@as(u32, 5), word(out.written(), 4));
    try std.testing.expectEqual(@as(u32, 3), word(out.written(), 24));
    try std.testing.expect(!try live.receive(&stream, &out.writer));
}

test "an IN URB waits beside an OUT one until the driver commits its packet" {
    const live = try std.testing.allocator.create(session.Session);
    defer std.testing.allocator.destroy(live);
    live.* = .{};
    var device = usbfs.Device{};
    open(&device, 2, 1, true);
    var input = submit(9, true, 1, 64);
    var stream: std.Io.Reader = .fixed(&input);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    _ = try live.receive(&stream, &out.writer);
    try std.testing.expectEqual(@as(usize, 0), try live.pump(&device, &out.writer));
    commit(&device, 2);
    try std.testing.expectEqual(@as(usize, 1), try live.pump(&device, &out.writer));
    try std.testing.expectEqual(@as(usize, wire.basic_len + 2), out.written().len);
    try std.testing.expectEqual(@as(u32, 2), word(out.written(), 24));
    try std.testing.expectEqualSlices(u8, "hi", out.written()[wire.basic_len..]);
    try std.testing.expectEqual(@as(usize, 0), live.pending());
}

test "an unlink drops the waiting URB, which then never answers" {
    const live = try std.testing.allocator.create(session.Session);
    defer std.testing.allocator.destroy(live);
    live.* = .{};
    var device = usbfs.Device{};
    open(&device, 2, 1, true);
    var input: [2 * wire.basic_len]u8 = undefined;
    input[0..wire.basic_len].* = submit(9, true, 1, 64);
    input[wire.basic_len..].* = unlink(10, 9);
    var stream: std.Io.Reader = .fixed(&input);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    _ = try live.receive(&stream, &out.writer);
    _ = try live.receive(&stream, &out.writer);
    try std.testing.expectEqual(wire.cmd.ret_unlink, word(out.written(), 0));
    try std.testing.expectEqual(@as(u32, 10), word(out.written(), 4));
    try std.testing.expectEqual(@as(i32, -104), @as(i32, @bitCast(word(out.written(), 20))));
    commit(&device, 2);
    try std.testing.expectEqual(@as(usize, 0), try live.pump(&device, &out.writer));
    try std.testing.expectEqual(@as(usize, wire.basic_len), out.written().len);
}

test "a URB longer than the session holds is refused after its payload is skipped" {
    const live = try std.testing.allocator.create(session.Session);
    defer std.testing.allocator.destroy(live);
    live.* = .{};
    const length = session.max_length + 1;
    const input = try std.testing.allocator.alloc(u8, wire.basic_len + length);
    defer std.testing.allocator.free(input);
    @memset(input, 0);
    input[0..wire.basic_len].* = submit(3, false, 2, length);
    var stream: std.Io.Reader = .fixed(input);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    _ = try live.receive(&stream, &out.writer);
    try std.testing.expectEqual(@as(i32, session.emsgsize), @as(i32, @bitCast(word(out.written(), 20))));
    try std.testing.expectEqual(@as(usize, 0), live.pending());
    try std.testing.expect(!try live.receive(&stream, &out.writer));
}
