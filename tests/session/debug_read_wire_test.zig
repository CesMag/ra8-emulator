//! Over-the-wire test for debugger reads over a peripheral window
//! (RA8EMU-948): a spawned `serve --stdio` session reads 16 bytes of the RTC
//! window, which a peripheral answers only a register at a time, and gets
//! the same bytes four word reads give. An SRAM read is unchanged.
const std = @import("std");
const ra8 = @import("ra8");
const test_paths = @import("test_paths");
const proto = ra8.rpc.session.rpc;
const Env = proto.Client.Env;

const elf_path = "tests/fixtures/fpu/fp_basic.elf";
const rtc_base: u32 = 0x4020_2000;
const sram_base: u32 = 0x2200_0000;

fn now() i64 {
    return std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds();
}

fn connect(client: *proto.Client, tx: []u8) !void {
    try client.greet(tx);
    const deadline = now() + 10_000;
    while (now() < deadline) {
        if (try client.poll(tx)) |arrival| switch (arrival) {
            .ready => return,
            else => return error.Unexpected,
        };
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.Timeout;
}

/// Read `into.len` bytes at `address` over the wire into `into`.
fn readMemory(client: *proto.Client, tx: []u8, address: u32, into: []u8) !void {
    const id = try client.call(proto.ReadMemory, @backingInt(proto.Method.read_memory), .{ .core = .cpu0, .address = address, .length = @intCast(into.len) }, 0, tx);
    const deadline = now() + 10_000;
    while (now() < deadline) {
        const arrival = (try client.poll(tx)) orelse {
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
            .ready => return error.Unexpected,
        }
    }
    return error.Timeout;
}

/// The range read whole, then a word at a time, must agree.
fn agrees(client: *proto.Client, tx: []u8, comptime len: usize, address: u32) !void {
    var whole: [len]u8 = undefined;
    try readMemory(client, tx, address, &whole);
    var words: [len]u8 = undefined;
    var at: usize = 0;
    while (at < len) : (at += 4) try readMemory(client, tx, address + @as(u32, @intCast(at)), words[at..][0..4]);
    try std.testing.expectEqualSlices(u8, &words, &whole);
}

test "a served session reads 16 bytes of the RTC window and SRAM as before" {
    const gpa = std.testing.allocator;
    var local: ra8.rpc.child_transport.Child = undefined;
    const argv = [_][]const u8{ test_paths.emulator, "serve", "--stdio", elf_path };
    try local.spawn(std.testing.io, &argv);
    var reaped = false;
    defer if (!reaped) local.close();
    const rx = try gpa.alloc(u8, 2 * Env.max_frame);
    defer gpa.free(rx);
    const tx = try gpa.alloc(u8, Env.max_frame);
    defer gpa.free(tx);
    var client = proto.Client.init(local.transport(), rx, proto.capabilities);
    try connect(&client, tx);

    try agrees(&client, tx, 16, rtc_base);
    try agrees(&client, tx, 64, sram_base);

    local.process.stdin.?.close(std.testing.io);
    local.process.stdin = null;
    const term = try local.process.wait(std.testing.io);
    reaped = true;
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);
}
