//! Over-the-wire test for debugger reads over a peripheral window
//! (RA8EMU-948): a spawned `serve --stdio` session reads 16 bytes of the RTC
//! window, which a peripheral answers only a register at a time, and gets
//! the same bytes four word reads give. An SRAM read is unchanged.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const test_paths = @import("test_paths");
const proto = ra8.rpc.session.rpc;
const session_link = gui_app.session_link;
const Link = session_link.Link;
const Env = proto.Client.Env;

const elf_path = "tests/fixtures/fpu/fp_basic.elf";
const rtc_base: u32 = 0x4020_2000;
const sram_base: u32 = 0x2200_0000;

fn now() i64 {
    return std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds();
}

fn connect(link: *Link) !void {
    const deadline = now() + 10_000;
    while (link.state == .connecting and now() < deadline) {
        _ = link.pump();
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(link.state == .connected);
}

/// Read `into.len` bytes at `address` over the wire into `into`.
fn readMemory(link: *Link, address: u32, into: []u8) !void {
    const id = try link.send(proto.ReadMemory, .read_memory, .{ .core = .cpu0, .address = address, .length = @intCast(into.len) });
    const deadline = now() + 10_000;
    while (now() < deadline) {
        if (link.state != .connected) return error.LinkLost;
        const arrival = link.pump() orelse {
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
            continue;
        };
        switch (arrival) {
            .response => |response| if (response.id == id) {
                const ok = switch (response.result) {
                    .ok => |bytes| bytes,
                    .err => return error.Refused,
                };
                const memory = try proto.decode(proto.Memory, ok);
                try std.testing.expectEqual(into.len, memory.bytes.len);
                return @memcpy(into, memory.bytes);
            },
            .event => {},
        }
    }
    return error.Timeout;
}

/// The range read whole, then a word at a time, must agree.
fn agrees(link: *Link, comptime len: usize, address: u32) !void {
    var whole: [len]u8 = undefined;
    try readMemory(link, address, &whole);
    var words: [len]u8 = undefined;
    var at: usize = 0;
    while (at < len) : (at += 4) try readMemory(link, address + @as(u32, @intCast(at)), words[at..][0..4]);
    try std.testing.expectEqualSlices(u8, &words, &whole);
}

test "a served session reads 16 bytes of the RTC window and SRAM as before" {
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

    try agrees(&link, 16, rtc_base);
    try agrees(&link, 64, sram_base);

    local.end();
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try local.reap());
}
