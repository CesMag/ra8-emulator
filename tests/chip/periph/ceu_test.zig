//! Covers src/chip/periph/ceu.zig: the CAPSR.CE arm, the frame the model writes
//! into the firmware's buffer, the event register a store may only clear,
//! and the arms this model declines rather than inventing a frame for.
const std = @import("std");
const ra8 = @import("ra8");

const ceu = ra8.chip.periph.ceu;
const Store = ra8.chip.core.cpu.memory.store.Store;
const Guest = ra8.chip.core.cpu.memory.guest.Guest;

/// The last page of SDRAM. The Zig core's store backs all of SDRAM, so the
/// buffer sits at its top: the tests that run a capture off the end of
/// memory still reach an address nothing backs.
const frame_base: u32 = ra8.chip.core.memmap.sdram_end - 0x1000;

fn at(offset: u32) u32 {
    return ceu.win_base + offset;
}

/// CAPWR: a capture window `width` bytes by `lines` lines.
fn window(width: u32, lines: u32) u32 {
    return width | lines << ceu.field.vertical_shift;
}

/// A CEU with memory behind it, and the frame buffer it captures into. The
/// Zig core's store backs SDRAM, so the buffer needs no map of its own.
const Bench = struct {
    store: *Store = undefined,
    core: Guest = undefined,
    unit: ceu.Ceu = undefined,

    fn open(self: *Bench) !void {
        self.store = try std.testing.allocator.create(Store);
        errdefer std.testing.allocator.destroy(self.store);
        self.store.* = try Store.init(null);
        self.core = .{ .store = self.store };
        self.unit = ceu.Ceu.init();
        self.unit.memory = self.core;
    }

    fn close(self: *Bench) void {
        self.store.deinit();
        std.testing.allocator.destroy(self.store);
    }

    /// Program a capture of `width` x `lines` into `destination`, with a
    /// destination line stride of `stride`, without arming it.
    fn program(self: *Bench, width: u32, lines: u32, stride: u32, destination: u32) void {
        self.unit.write(at(ceu.off.capwr), 4, window(width, lines));
        self.unit.write(at(ceu.off.cdwdr), 4, stride);
        self.unit.write(at(ceu.off.cdayr), 4, destination);
    }

    fn arm(self: *Bench) void {
        self.unit.write(at(ceu.off.capsr), 4, ceu.field.capture_enable);
    }

    fn byte(self: *Bench, address: u32) !u8 {
        var cell: [1]u8 = undefined;
        try self.core.read(address, &cell);
        return cell[0];
    }
};

test "at reset nothing has been captured and the status reads idle" {
    var unit = ceu.Ceu.init();
    try std.testing.expect(unit.quiet());
    try std.testing.expectEqual(@as(u32, 0), unit.read(at(ceu.off.capsr), 4));
    try std.testing.expectEqual(@as(u32, 0), unit.read(at(ceu.off.cstsr), 4));
    try std.testing.expectEqual(@as(u32, 0), unit.read(at(ceu.off.cdssr), 4));
    try std.testing.expectEqual(@as(u32, 0), unit.frames);
}

test "an arm with no geometry captures nothing and raises no frame end" {
    var bench = Bench{};
    try bench.open();
    defer bench.close();
    bench.unit.write(at(ceu.off.cdayr), 4, frame_base);
    bench.arm();
    try std.testing.expectEqual(@as(u32, 0), bench.unit.frames);
    try std.testing.expectEqual(ceu.Decline.unprogrammed, bench.unit.last_decline.?);
    try std.testing.expectEqual(@as(u32, 0), bench.unit.read(at(ceu.off.cetcr), 4));
}

test "an arm with no destination address captures nothing" {
    var bench = Bench{};
    try bench.open();
    defer bench.close();
    bench.program(8, 4, 8, 0);
    bench.arm();
    try std.testing.expectEqual(ceu.Decline.unaddressed, bench.unit.last_decline.?);
    try std.testing.expectEqual(@as(u32, 0), bench.unit.frames);
}

test "an arm on a board with no memory is declined, not counted" {
    var unit = ceu.Ceu.init();
    unit.write(at(ceu.off.capwr), 4, window(8, 4));
    unit.write(at(ceu.off.cdayr), 4, frame_base);
    unit.write(at(ceu.off.capsr), 4, ceu.field.capture_enable);
    try std.testing.expectEqual(ceu.Decline.unbacked, unit.last_decline.?);
    try std.testing.expectEqual(@as(u32, 0), unit.frames);
}

test "an armed capture writes the gradient, latches CPE and reports the bytes" {
    var bench = Bench{};
    try bench.open();
    defer bench.close();
    bench.program(8, 4, 8, frame_base);
    bench.arm();
    try std.testing.expectEqual(@as(u32, 1), bench.unit.frames);
    try std.testing.expectEqual(@as(u32, 32), bench.unit.last_bytes);
    try std.testing.expectEqual(ceu.field.frame_end, bench.unit.read(at(ceu.off.cetcr), 4));
    try std.testing.expectEqual(@as(u32, 32), bench.unit.read(at(ceu.off.cdssr), 4));
    // (x + y) & 0xFF, so the first pixel of row 3 is 3 and its last is 10.
    try std.testing.expectEqual(@as(u8, 0), try bench.byte(frame_base));
    try std.testing.expectEqual(@as(u8, 3), try bench.byte(frame_base + 24));
    try std.testing.expectEqual(@as(u8, 10), try bench.byte(frame_base + 31));
}

test "a completed single shot clears CAPSR.CE" {
    var bench = Bench{};
    try bench.open();
    defer bench.close();
    bench.program(8, 4, 8, frame_base);
    bench.arm();
    try std.testing.expectEqual(@as(u32, 0), bench.unit.read(at(ceu.off.capsr), 4));
}

test "a stride wider than the line leaves the padding untouched" {
    var bench = Bench{};
    try bench.open();
    defer bench.close();
    // Poison the padding byte, then capture 8 bytes per line on a 16-byte
    // stride. dev fills the stride, so this byte comes back as pattern.
    try bench.core.write(frame_base + 8, &[_]u8{0xAA});
    bench.program(8, 4, 16, frame_base);
    bench.arm();
    try std.testing.expectEqual(@as(u32, 1), bench.unit.frames);
    try std.testing.expectEqual(@as(u8, 0xAA), try bench.byte(frame_base + 8));
    // Row 1 starts a whole stride in, not a line in.
    try std.testing.expectEqual(@as(u8, 1), try bench.byte(frame_base + 16));
}

test "a geometry past what the model synthesises is refused, not shrunk" {
    var bench = Bench{};
    try bench.open();
    defer bench.close();
    // CAPWR.HWDTH is 13 bits, so it cannot name a line this long; CMCYR.HCYL
    // is 14 and can, which is the only way an image reaches the bound.
    bench.unit.write(at(ceu.off.cmcyr), 4, (ceu.bound.line_bytes + 1) |
        @as(u32, 1) << ceu.field.vertical_shift);
    bench.unit.write(at(ceu.off.cdayr), 4, frame_base);
    bench.arm();
    try std.testing.expectEqual(ceu.Decline.oversized, bench.unit.last_decline.?);
    try std.testing.expectEqual(@as(u32, 0), bench.unit.frames);
    try std.testing.expectEqual(@as(u32, 0), bench.unit.read(at(ceu.off.cetcr), 4));
}

test "a capture the memory refuses raises no frame end" {
    var bench = Bench{};
    try bench.open();
    defer bench.close();
    // One page is mapped, so a four-line frame runs off the end of it.
    bench.program(0x800, 4, 0x800, frame_base);
    bench.arm();
    try std.testing.expectEqual(ceu.Decline.faulted, bench.unit.last_decline.?);
    try std.testing.expectEqual(@as(u32, 1), bench.unit.faults);
    try std.testing.expectEqual(@as(u32, 0), bench.unit.frames);
    try std.testing.expectEqual(@as(u32, 0), bench.unit.read(at(ceu.off.cetcr), 4));
}

test "firmware cannot raise a frame end it never captured" {
    var unit = ceu.Ceu.init();
    unit.write(at(ceu.off.cetcr), 4, ceu.field.frame_end);
    try std.testing.expectEqual(@as(u32, 0), unit.read(at(ceu.off.cetcr), 4));
    try std.testing.expectEqual(@as(u32, 1), unit.faked);
    try std.testing.expect(!unit.quiet());
}

test "a store to CETCR clears the flag the capture raised" {
    var bench = Bench{};
    try bench.open();
    defer bench.close();
    bench.program(8, 4, 8, frame_base);
    bench.arm();
    bench.unit.write(at(ceu.off.cetcr), 4, 0);
    try std.testing.expectEqual(@as(u32, 0), bench.unit.read(at(ceu.off.cetcr), 4));
    try std.testing.expectEqual(@as(u32, 0), bench.unit.faked);
}

test "CPKIL drops the pending event and the arm, and self-clears" {
    var bench = Bench{};
    try bench.open();
    defer bench.close();
    bench.program(8, 4, 8, frame_base);
    bench.arm();
    bench.unit.write(at(ceu.off.capsr), 4, ceu.field.capture_kill);
    try std.testing.expectEqual(@as(u32, 0), bench.unit.read(at(ceu.off.cetcr), 4));
    try std.testing.expectEqual(@as(u32, 0), bench.unit.read(at(ceu.off.capsr), 4));
    try std.testing.expectEqual(@as(u32, 1), bench.unit.resets);
}

test "CMCYR stands in for the geometry while CAPWR is still zero" {
    var bench = Bench{};
    try bench.open();
    defer bench.close();
    bench.unit.write(at(ceu.off.cmcyr), 4, 8 | @as(u32, 2) << ceu.field.vertical_shift);
    bench.unit.write(at(ceu.off.cdayr), 4, frame_base);
    bench.arm();
    try std.testing.expectEqual(@as(u32, 1), bench.unit.frames);
    try std.testing.expectEqual(@as(u32, 8), bench.unit.last_width);
    try std.testing.expectEqual(@as(u32, 2), bench.unit.last_lines);
}

test "a byte store to CAPSR leaves the bytes above it standing" {
    var bench = Bench{};
    try bench.open();
    defer bench.close();
    bench.program(8, 4, 8, frame_base);
    bench.unit.write(at(ceu.off.capsr), 4, 0x5A5A_5A00);
    bench.unit.write(at(ceu.off.capsr), 1, ceu.field.capture_enable);
    try std.testing.expectEqual(@as(u32, 1), bench.unit.frames);
    // CE cleared by the completed shot; the shadowed bytes above survive.
    try std.testing.expectEqual(@as(u32, 0x5A5A_5A00), bench.unit.read(at(ceu.off.capsr), 4));
}

test "a store to CDSSR cannot dress up the byte count" {
    var bench = Bench{};
    try bench.open();
    defer bench.close();
    bench.unit.write(at(ceu.off.cdssr), 4, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u32, 0), bench.unit.read(at(ceu.off.cdssr), 4));
    bench.program(8, 4, 8, frame_base);
    bench.arm();
    try std.testing.expectEqual(@as(u32, 32), bench.unit.read(at(ceu.off.cdssr), 4));
}

test "a capture the memory ends partway books the lines that landed" {
    var bench = Bench{};
    try bench.open();
    defer bench.close();
    // One 0x1000 page is mapped, so lines 0 and 1 land whole and line 2
    // starts at the first address past the end of it.
    bench.program(0x800, 4, 0x800, frame_base);
    bench.arm();
    try std.testing.expectEqual(ceu.Decline.faulted, bench.unit.last_decline.?);
    try std.testing.expectEqual(@as(u32, 1), bench.unit.short_frames);
    try std.testing.expectEqual(@as(u32, 2), bench.unit.short_lines);
    try std.testing.expectEqual(@as(u32, 0x1000), bench.unit.short_bytes);
    try std.testing.expectEqual(@as(u32, 0), bench.unit.frames);
}

test "the lines a cut-short capture painted stay in the buffer" {
    var bench = Bench{};
    try bench.open();
    defer bench.close();
    bench.program(0x800, 4, 0x800, frame_base);
    bench.arm();
    // (x + y) & 0xFF: the first byte of row 0, and of row 1 a line in.
    try std.testing.expectEqual(@as(u8, 0), try bench.byte(frame_base));
    try std.testing.expectEqual(@as(u8, 1), try bench.byte(frame_base + 0x800));
}

test "a cut-short capture leaves CPE, CE and CDSSR as the firmware sees them" {
    var bench = Bench{};
    try bench.open();
    defer bench.close();
    bench.program(8, 4, 8, frame_base);
    bench.arm();
    bench.unit.write(at(ceu.off.cetcr), 4, 0);
    // A second arm that runs off the end of the page changes nothing the
    // firmware can read: the byte count is still the frame that finished.
    bench.program(0x800, 4, 0x800, frame_base);
    bench.arm();
    try std.testing.expectEqual(@as(u32, 0), bench.unit.read(at(ceu.off.cetcr), 4));
    try std.testing.expectEqual(ceu.field.capture_enable, bench.unit.read(at(ceu.off.capsr), 4));
    try std.testing.expectEqual(@as(u32, 32), bench.unit.read(at(ceu.off.cdssr), 4));
    try std.testing.expectEqual(@as(u32, 1), bench.unit.frames);
}

test "a capture refused on its very first chunk books no short frame" {
    var bench = Bench{};
    try bench.open();
    defer bench.close();
    bench.program(8, 4, 8, frame_base + 0x1000);
    bench.arm();
    try std.testing.expectEqual(ceu.Decline.faulted, bench.unit.last_decline.?);
    try std.testing.expectEqual(@as(u32, 1), bench.unit.faults);
    try std.testing.expectEqual(@as(u32, 0), bench.unit.short_frames);
    try std.testing.expectEqual(@as(u32, 0), bench.unit.short_bytes);
}

test "a line refused halfway books the bytes before the refused chunk" {
    var bench = Bench{};
    try bench.open();
    defer bench.close();
    // One line of 0x900 bytes starting 0x800 into the page: 0x800 of it fits.
    bench.program(0x900, 1, 0x900, frame_base + 0x800);
    bench.arm();
    try std.testing.expectEqual(@as(u32, 1), bench.unit.short_frames);
    try std.testing.expectEqual(@as(u32, 0), bench.unit.short_lines);
    try std.testing.expectEqual(@as(u32, 0x800), bench.unit.short_bytes);
}

// The camera sources the CEU captures from; tests/all.zig is full.
test {
    _ = @import("camera/frame_source_test.zig");
    _ = @import("camera/gradient_source_test.zig");
}

/// A source that records the emulated instant each capture asked for.
const Stamp = struct {
    seen: [2]u64 = .{ 0, 0 },
    frames: usize = 0,

    fn source(self: *Stamp) ceu.camera.frame_source.FrameSource {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable = ceu.camera.frame_source.FrameSource.VTable{ .frame = frame, .fill = fill, .close = close };

    fn frame(context: *anyopaque, when: u64, _: ceu.camera.frame_source.Shape) void {
        const self: *Stamp = @ptrCast(@alignCast(context));
        if (self.frames < self.seen.len) self.seen[self.frames] = when;
        self.frames += 1;
    }

    fn fill(_: *anyopaque, _: u32, _: u32, out: []u8) void {
        @memset(out, 0);
    }

    fn close(_: *anyopaque) void {}
};

test "each arm hands the source the board's virtual time at that moment" {
    var bench = Bench{};
    try bench.open();
    defer bench.close();
    var clock = ra8.chip.periph.clocks.timebase.TimeBase{};
    var stamp = Stamp{};
    bench.unit.source = stamp.source();
    bench.unit.clock = &clock;
    bench.program(16, 2, 16, frame_base);
    clock.advance(2_000);
    bench.arm();
    clock.advance(40_000_000);
    bench.arm();
    try std.testing.expectEqual(@as(usize, 2), stamp.frames);
    try std.testing.expectEqual(@as(u64, 2_000), stamp.seen[0]);
    try std.testing.expectEqual(@as(u64, 40_002_000), stamp.seen[1]);
}

test "a CEU with no clock hands its source time 0" {
    var bench = Bench{};
    try bench.open();
    defer bench.close();
    var stamp = Stamp{};
    bench.unit.source = stamp.source();
    bench.program(16, 2, 16, frame_base);
    bench.arm();
    try std.testing.expectEqual(@as(usize, 1), stamp.frames);
    try std.testing.expectEqual(@as(u64, 0), stamp.seen[0]);
}
