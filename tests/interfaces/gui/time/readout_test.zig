//! Host tests for the time bar's clock readout (RA8EMU-806): the achieved
//! speed and when it shows, the line it reads, and the readout following a
//! spawned `serve --stdio` session's virtual time and RTC date (RA8EMU-809)
//! across a run, including a date written into its RTC counters.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const test_paths = @import("test_paths");
const proto = ra8.rpc.session.rpc;
const session_link = gui_app.session_link;
const time_readout = gui_app.time.readout;
const Link = session_link.Link;
const Readout = time_readout.Readout;
const Status = gui_app.status.bar.Status;
const Env = proto.Client.Env;

const elf_path = "tests/fixtures/fpu/fp_basic.elf";

test "the achieved speed shows only when short of the request, never for max" {
    const from: time_readout.Sample = .{ .wall_ns = 1_000_000_000, .virtual_ns = 0 };
    const to: time_readout.Sample = .{ .wall_ns = 2_000_000_000, .virtual_ns = 420_000_000 };
    try std.testing.expectEqual(@as(?u64, 420), time_readout.achieved(from, to));
    try std.testing.expectEqual(@as(?u64, null), time_readout.achieved(to, from));
    try std.testing.expect(time_readout.short(420, 1000));
    try std.testing.expect(!time_readout.short(960, 1000));
    try std.testing.expect(!time_readout.short(1, 0));

    var buf: [96]u8 = undefined;
    var readout: Readout = .{};
    try std.testing.expectEqualStrings("T+--", try readout.text(1000, &buf));
    readout.virtual_ns = 3_723_456_000_000;
    readout.achieved_milli = 420;
    try std.testing.expectEqualStrings("T+1:02:03.456 | 0.42x of 1x", try readout.text(1000, &buf));
    try std.testing.expectEqualStrings("T+1:02:03.456", try readout.text(0, &buf));
}

test "the RTC date leads the line when the session has one" {
    var buf: [96]u8 = undefined;
    var readout: Readout = .{};
    readout.virtual_ns = 3_723_456_000_000;
    readout.date = .{ .year = 2026, .month = 10, .day = 8, .hour = 9, .minute = 47, .second = 5 };
    try std.testing.expectEqualStrings("2026-10-08 09:47:05 | T+1:02:03.456", try readout.text(1000, &buf));
    readout.date = null;
    try std.testing.expectEqualStrings("T+1:02:03.456", try readout.text(1000, &buf));
}

fn connect(link: *Link) !void {
    const deadline = std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() + 10_000;
    while (link.state == .connecting and std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() < deadline) {
        _ = link.pump();
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(link.state == .connected);
}

fn busy(readout: *const Readout, status: *const Status) bool {
    return readout.waiting() or status.load_id != null or status.pc_id != null or status.run == .running;
}

/// Pump the link into the readout and the status until nothing is
/// outstanding, for ten seconds.
fn settle(link: *Link, readout: *Readout, status: *Status) !void {
    const deadline = std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() + 10_000;
    while (busy(readout, status)) {
        if (std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() > deadline) return error.Timeout;
        if (link.state != .connected) return error.LinkLost;
        const arrival = link.pump() orelse {
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
            continue;
        };
        readout.observe(arrival, @intCast(std.Io.Timestamp.now(std.testing.io, .awake).toNanoseconds()));
        status.observe(link, arrival);
    }
}

test "the readout follows a local session's virtual time across a run" {
    const gpa = std.testing.allocator;
    var local: session_link.Local = undefined;
    try local.spawn(std.testing.io, test_paths.emulator, elf_path);
    errdefer local.child.kill(std.testing.io);
    const rx = try gpa.alloc(u8, 2 * Env.max_frame);
    defer gpa.free(rx);
    const tx = try gpa.alloc(u8, Env.max_frame);
    defer gpa.free(tx);
    var link: Link = undefined;
    link.open(local.transport(), rx, tx);
    try connect(&link);

    var readout: Readout = .{};
    var status: Status = .{};
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, elf_path, gpa, .limited(1 << 20));
    defer gpa.free(bytes);
    try status.load(&link, elf_path, bytes);
    try readout.poll(&link);
    try settle(&link, &readout, &status);
    const before = readout.virtual_ns orelse return error.NoTime;

    try status.go(&link, .cont, 200_000);
    try settle(&link, &readout, &status);
    try readout.poll(&link);
    try settle(&link, &readout, &status);
    try std.testing.expect(readout.virtual_ns.? > before);

    var buf: [96]u8 = undefined;
    try std.testing.expect(!readout.no_rtc);
    const date = readout.date orelse return error.NoDate;
    var date_buf: [19]u8 = undefined;
    try std.testing.expectEqualStrings("2000-01-01 00:00:00", date.format(&date_buf));
    try std.testing.expect(std.mem.startsWith(u8, try readout.text(1000, &buf), "2000-01-01 00:00:00 | T+"));

    local.end();
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try local.reap());
}

/// The RTC counters and the date written into them: year, month, day,
/// hour, minute, second, each a BCD byte at its RCR offset.
const rtc_base: u32 = 0x4020_2000;
const set_date = [_][2]u8{ .{ 0x0E, 0x26 }, .{ 0x0C, 0x10 }, .{ 0x0A, 0x08 }, .{ 0x06, 0x09 }, .{ 0x04, 0x47 }, .{ 0x02, 0x05 } };

/// Write one byte through the session and wait for its answer, passing
/// everything else that arrives to the readout and the status.
fn writeByte(link: *Link, readout: *Readout, status: *Status, address: u32, byte: u8) !void {
    const id = try link.send(proto.WriteMemory, .write_memory, .{ .core = .cpu0, .address = address, .bytes = &.{byte} });
    const deadline = std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() + 10_000;
    while (std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() < deadline) {
        if (link.state != .connected) return error.LinkLost;
        const arrival = link.pump() orelse {
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
            continue;
        };
        switch (arrival) {
            .response => |response| if (response.id == id) {
                if (response.result == .err) return error.WriteRefused;
                return;
            },
            .event => {},
        }
        readout.observe(arrival, 0);
        status.observe(link, arrival);
    }
    return error.Timeout;
}

test "the readout shows the date written into a served session's RTC" {
    const gpa = std.testing.allocator;
    var local: session_link.Local = undefined;
    try local.spawn(std.testing.io, test_paths.emulator, elf_path);
    errdefer local.child.kill(std.testing.io);
    const rx = try gpa.alloc(u8, 2 * Env.max_frame);
    defer gpa.free(rx);
    const tx = try gpa.alloc(u8, Env.max_frame);
    defer gpa.free(tx);
    var link: Link = undefined;
    link.open(local.transport(), rx, tx);
    try connect(&link);

    var readout: Readout = .{};
    var status: Status = .{};
    // The clock is stopped out of reset, which is when the counters take a write.
    for (set_date) |field| try writeByte(&link, &readout, &status, rtc_base + field[0], field[1]);
    try readout.poll(&link);
    try settle(&link, &readout, &status);
    const date = readout.date orelse return error.NoDate;
    var date_buf: [19]u8 = undefined;
    try std.testing.expectEqualStrings("2026-10-08 09:47:05", date.format(&date_buf));
    var buf: [96]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, try readout.text(1000, &buf), "2026-10-08 09:47:05 | T+"));

    local.end();
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try local.reap());
}
