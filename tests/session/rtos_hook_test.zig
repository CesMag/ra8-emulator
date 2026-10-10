//! Tests for src/session/rtos_hook.zig: which stores the hook takes for a
//! switch, what an image without ThreadX gets, and what the report prints.
const std = @import("std");
const ra8 = @import("ra8");
const rtos_hook = ra8.session.step_hook.rtos_hook;

fn bareImage(buffer: *[@sizeOf(ra8.board.image.elf.Header)]u8) !ra8.board.image.elf.Image {
    @memset(buffer, 0);
    const head: *align(1) ra8.board.image.elf.Header = std.mem.bytesAsValue(ra8.board.image.elf.Header, buffer);
    head.magic = .{ 0x7F, 'E', 'L', 'F' };
    head.class = 1;
    head.data = 1;
    head.e_machine = ra8.board.image.elf.em_arm;
    return ra8.board.image.elf.Image.init(buffer);
}

test "a full word to the pointer is a switch, anything else is not" {
    var tracer = rtos_hook.Tracer{ .address = 0x2200_1ABC };
    tracer.onStore(0x2200_1ABC, 4, 0x2200_10F0);
    tracer.onStore(0x2200_1ABE, 2, 0x1234);
    tracer.onStore(0x2200_1ABC, 1, 0);
    try std.testing.expectEqual(@as(usize, 1), tracer.trace.list().len);
    try std.testing.expectEqual(@as(u32, 0x2200_10F0), tracer.trace.list()[0].thread);
}

test "each switch is stamped from the run's clock as it lands" {
    var ticks: u64 = 3;
    var tracer = rtos_hook.Tracer{ .address = 0x2200_1ABC, .now = &ticks };
    tracer.onStore(0x2200_1ABC, 4, 0x2200_10F0);
    ticks = 9;
    tracer.onStore(0x2200_1ABC, 4, 0);
    try std.testing.expectEqual(@as(u64, 3), tracer.trace.list()[0].when);
    try std.testing.expectEqual(@as(u64, 9), tracer.trace.list()[1].when);
}

test "no flag traces nothing, and an image without ThreadX traces nothing" {
    var buffer: [@sizeOf(ra8.board.image.elf.Header)]u8 = undefined;
    const image = try bareImage(&buffer);
    try std.testing.expect(rtos_hook.resolve(image, null) == null);
    try std.testing.expect(rtos_hook.resolve(image, .{}) == null);
}

test "the report lists the opening switches of threadx_blink in order" {
    // The pointer values threadx_blink.elf writes in its first 3M
    // instructions: the scheduler idles, runs one thread, idles, runs the
    // other, idles.
    var tracer = rtos_hook.Tracer{ .address = 0x2200_1ABC };
    for ([_]u32{ 0, 0x2200_10F0, 0, 0x2200_11A0, 0 }) |value| tracer.onStore(0x2200_1ABC, 4, value);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try rtos_hook.print(&out.writer, &tracer, rtos_hook.names.none);
    const want =
        \\  rtos trace    : _tx_thread_current_ptr @0x22001ABC, 5 event(s)
        \\                  tick 0 cpu0 idle
        \\                  tick 0 cpu0 -> 0x220010F0
        \\                  tick 0 cpu0 idle
        \\                  tick 0 cpu0 -> 0x220011A0
        \\                  tick 0 cpu0 idle
        \\
    ;
    try std.testing.expectEqualStrings(want, out.written());
}

/// threadx_blink's two TX_THREAD blocks, as far as their name pointers, and
/// the names those point at.
const Blink = struct {
    pub fn read(_: Blink, address: u32, into: []u8) bool {
        const word: ?u32 = switch (address) {
            0x2200_10F0 + 40 => 0x0200_1000,
            0x2200_11A0 + 40 => 0x0200_1008,
            else => null,
        };
        if (word) |value| {
            if (into.len != 4) return false;
            std.mem.writeInt(u32, into[0..4], value, .little);
            return true;
        }
        const text = "blink_a\x00blink_b\x00";
        if (address < 0x0200_1000 or address + into.len > 0x0200_1000 + text.len) return false;
        @memcpy(into, text[address - 0x0200_1000 ..][0..into.len]);
        return true;
    }
};

test "each switch carries the name its control block points at" {
    var tracer = rtos_hook.Tracer{ .address = 0x2200_1ABC };
    for ([_]u32{ 0, 0x2200_10F0, 0, 0x2200_11A0, 0x2200_1234 }) |value| tracer.onStore(0x2200_1ABC, 4, value);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try rtos_hook.print(&out.writer, &tracer, Blink{});
    const want =
        \\  rtos trace    : _tx_thread_current_ptr @0x22001ABC, 5 event(s)
        \\                  tick 0 cpu0 idle
        \\                  tick 0 cpu0 -> 0x220010F0 blink_a
        \\                  tick 0 cpu0 idle
        \\                  tick 0 cpu0 -> 0x220011A0 blink_b
        \\                  tick 0 cpu0 -> 0x22001234
        \\
    ;
    try std.testing.expectEqualStrings(want, out.written());
}

test "exceptions print between the switches they bracket" {
    // The opening of threadx_blink.elf with --trace-rtos: SysTick, then the
    // PendSV that switches to the first thread.
    var tracer = rtos_hook.Tracer{ .address = 0x2200_1ABC };
    tracer.trace.exception(0, 1, .enter, 15);
    tracer.trace.exception(0, 1, .leave, 15);
    tracer.trace.exception(0, 1, .enter, 14);
    tracer.onStore(0x2200_1ABC, 4, 0x2200_10F0);
    tracer.trace.exception(0, 1, .leave, 14);
    tracer.trace.exception(0, 2, .enter, 16 + 7);
    tracer.trace.exception(0, 2, .leave, 9);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try rtos_hook.print(&out.writer, &tracer, Blink{});
    const want =
        \\  rtos trace    : _tx_thread_current_ptr @0x22001ABC, 7 event(s)
        \\                  tick 1 cpu0 enter SysTick
        \\                  tick 1 cpu0 leave SysTick
        \\                  tick 1 cpu0 enter PendSV
        \\                  tick 0 cpu0 -> 0x220010F0 blink_a
        \\                  tick 1 cpu0 leave PendSV
        \\                  tick 2 cpu0 enter IRQ7
        \\                  tick 2 cpu0 leave exception 9
        \\
    ;
    try std.testing.expectEqualStrings(want, out.written());
}

test "a CPU1 tracer tags its events and its header cpu1" {
    var tracer = rtos_hook.Tracer{ .address = 0x2200_1ABC, .core = 1 };
    tracer.trace.exception(1, 4, .enter, 14);
    tracer.onStore(0x2200_1ABC, 4, 0x2200_10F0);
    tracer.trace.exception(1, 4, .leave, 14);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try rtos_hook.print(&out.writer, &tracer, Blink{});
    const want =
        \\  rtos cpu1     : _tx_thread_current_ptr @0x22001ABC, 3 event(s)
        \\                  tick 4 cpu1 enter PendSV
        \\                  tick 0 cpu1 -> 0x220010F0 blink_a
        \\                  tick 4 cpu1 leave PendSV
        \\
    ;
    try std.testing.expectEqualStrings(want, out.written());
}

test "a CPU1 image without ThreadX traces nothing, and no flag traces nothing" {
    var buffer: [@sizeOf(ra8.board.image.elf.Header)]u8 = undefined;
    const image = try bareImage(&buffer);
    try std.testing.expect(rtos_hook.resolveOn(image, .{}, 1) == null);
    try std.testing.expect(rtos_hook.resolveOn(image, null, 1) == null);
}

test "no CPU1 prints nothing for CPU1" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try rtos_hook.second.print(&out.writer, std.testing.io, .{ .trace_rtos = true, .cpu_load = true }, null);
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}

test "no trace asked for prints nothing" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try rtos_hook.print(&out.writer, null, rtos_hook.names.none);
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}
