//! Covers src/chip/core/cpu/boot.zig.
const std = @import("std");
const ra8 = @import("ra8");
const memmap = ra8.chip.core.memmap;
const boot = ra8.chip.core.cpu.boot;
const elf = ra8.board.image.elf;
const Store = ra8.chip.core.cpu.memory.store.Store;
const Until = ra8.chip.core.stop.until.Until;

/// Copies bytes into the store, the way a loader would.
fn put(store: *Store, address: u32, bytes: []const u8) !void {
    const span = store.span(address, bytes.len) orelse return error.Unbacked;
    @memcpy(span, bytes);
}

/// A vector table at the base of SRAM pointing at code right after it:
/// bf00 nop ; f3af 8000 nop.w ; ba80, unallocated on Armv8-M.
fn loadTiny(store: *Store) !void {
    const base = memmap.sram_base;
    var image: [16]u8 = undefined;
    std.mem.writeInt(u32, image[0..4], base + 0x1000, .little);
    std.mem.writeInt(u32, image[4..8], (base + 8) | 1, .little);
    @memcpy(image[8..16], &[_]u8{ 0x00, 0xBF, 0xAF, 0xF3, 0x00, 0x80, 0x80, 0xBA });
    try put(store, base, &image);
}

test "a zig run stops on the first unknown encoding and says where" {
    var store = try Store.init(null);
    defer store.deinit();
    try loadTiny(&store);
    var buf: [128]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buf);
    const status = try boot.run(&stream, .{ .store = &store }, memmap.sram_base, 100, null);
    try std.testing.expectEqual(@as(u8, 1), status);
    var want: [128]u8 = undefined;
    const line = try std.fmt.bufPrint(&want, "zig core: unknown encoding at 0x{x:0>8}: 0xba80 after 2 instructions\n", .{memmap.sram_base + 0xE});
    try std.testing.expectEqualStrings(line, stream.buffered());
}

test "a zig run that spends its budget is clean" {
    var store = try Store.init(null);
    defer store.deinit();
    try loadTiny(&store);
    var buf: [128]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buf);
    try std.testing.expectEqual(@as(u8, 0), try boot.run(&stream, .{ .store = &store }, memmap.sram_base, 1, null));
    try std.testing.expect(std.mem.startsWith(u8, stream.buffered(), "zig core: ran 1 instructions clean"));
}

test "no vector table is said plainly" {
    var store = try Store.init(null);
    defer store.deinit();
    // Nothing backs 0x7000_0000, so reset cannot read a vector table there.
    var buf: [128]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buf);
    try std.testing.expectEqual(@as(u8, 1), try boot.run(&stream, .{ .store = &store }, 0x7000_0000, 1, null));
    try std.testing.expect(std.mem.startsWith(u8, stream.buffered(), "zig core: no vector table"));
}

/// Counts the boundaries a run closes and how many instructions they carry.
const Edges = struct {
    width: u32,
    closes: u32 = 0,
    charged: u64 = 0,

    fn boundary(self: *Edges) boot.Boundary {
        return .{ .context = self, .widthFn = widthOf, .closeFn = closeOf };
    }

    fn widthOf(context: *anyopaque) u32 {
        const self: *Edges = @ptrCast(@alignCast(context));
        return self.width;
    }

    fn closeOf(context: *anyopaque, instructions: u32) anyerror!void {
        const self: *Edges = @ptrCast(@alignCast(context));
        self.closes += 1;
        self.charged += instructions;
    }
};

/// A vector table at the base of SRAM pointing at `b .` (0xe7fe).
fn loadSpin(store: *Store) !void {
    const base = memmap.sram_base;
    var image: [10]u8 = undefined;
    std.mem.writeInt(u32, image[0..4], base + 0x1000, .little);
    std.mem.writeInt(u32, image[4..8], (base + 8) | 1, .little);
    @memcpy(image[8..10], &[_]u8{ 0xFE, 0xE7 });
    try put(store, base, &image);
}

test "a zig run on the board closes a boundary after every stretch, the short last one too" {
    var store = try Store.init(null);
    defer store.deinit();
    try loadSpin(&store);
    var edges: Edges = .{ .width = 3 };
    var ran: u64 = 0;
    var buf: [128]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buf);
    var periph = ra8.chip.periph.registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    const status = try boot.runOnBoard(&stream, .{ .store = &store }, &periph, memmap.sram_base, 10, &ran, .{ .boundary = edges.boundary() });
    try std.testing.expectEqual(@as(u8, 0), status);
    try std.testing.expectEqual(@as(u64, 10), ran);
    try std.testing.expectEqual(@as(u32, 4), edges.closes);
    try std.testing.expectEqual(@as(u64, 10), edges.charged);
}

test "a zig run hands back its registers as it left them (RA8EMU-579)" {
    var store = try Store.init(null);
    defer store.deinit();
    try loadSpin(&store);
    var final: boot.Regs = .{};
    var buf: [128]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buf);
    var periph = ra8.chip.periph.registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    _ = try boot.runOnBoard(&stream, .{ .store = &store }, &periph, memmap.sram_base, 10, null, .{ .final = &final });
    try std.testing.expectEqual(memmap.sram_base + 8, final.pc);
    try std.testing.expectEqual(memmap.sram_base + 0x1000, final.get(13));
}

test "a stretch the core stops inside is never closed" {
    var store = try Store.init(null);
    defer store.deinit();
    try loadTiny(&store);
    var edges: Edges = .{ .width = 5 };
    var buf: [128]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buf);
    var periph = ra8.chip.periph.registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    const status = try boot.runOnBoard(&stream, .{ .store = &store }, &periph, memmap.sram_base, 100, null, .{ .boundary = edges.boundary() });
    try std.testing.expectEqual(@as(u8, 1), status);
    try std.testing.expectEqual(@as(u32, 0), edges.closes);
}

test "a console success reached before an unknown encoding ends the Zig run" {
    var store = try Store.init(null);
    defer store.deinit();
    try loadTiny(&store);
    var edges: Edges = .{ .width = 5 };
    var until = Until{ .needle = "PASS", .seen = true };
    var buf: [128]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buf);
    var periph = ra8.chip.periph.registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    const status = try boot.runOnBoard(
        &stream,
        .{ .store = &store },
        &periph,
        memmap.sram_base,
        100,
        null,
        .{ .boundary = edges.boundary(), .until = &until },
    );
    try std.testing.expectEqual(@as(u8, 0), status);
    try std.testing.expect(until.reached);
    try std.testing.expectEqual(@as(u32, 0), edges.closes);
    try std.testing.expectEqualStrings(
        "zig core: ran 1 instructions clean, pc 0x2200000A\nstopped clean on the console line \"PASS\", pc 0x2200000A\n",
        stream.buffered(),
    );
}

/// A vector table at the base of SRAM pointing at an idle loop:
/// bf30 wfi ; e7fd b back to the wfi.
fn loadIdle(store: *Store) !void {
    const base = memmap.sram_base;
    var image: [12]u8 = undefined;
    std.mem.writeInt(u32, image[0..4], base + 0x1000, .little);
    std.mem.writeInt(u32, image[4..8], (base + 8) | 1, .little);
    @memcpy(image[8..12], &[_]u8{ 0x30, 0xBF, 0xFD, 0xE7 });
    try put(store, base, &image);
}

test "a core asleep in wfi closes every stretch at once without retiring" {
    var store = try Store.init(null);
    defer store.deinit();
    try loadIdle(&store);
    var edges: Edges = .{ .width = 4 };
    var ran: u64 = 0;
    var buf: [128]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buf);
    var periph = ra8.chip.periph.registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    const status = try boot.runOnBoard(&stream, .{ .store = &store }, &periph, memmap.sram_base, 20, &ran, .{ .boundary = edges.boundary() });
    try std.testing.expectEqual(@as(u8, 0), status);
    try std.testing.expectEqual(@as(u64, 1), ran);
    try std.testing.expectEqual(@as(u32, 5), edges.closes);
    try std.testing.expectEqual(@as(u64, 20), edges.charged);
}

const pacbti_image = @embedFile("../../../fixtures/pacbti/pacbti_smoke.elf");

test "a PACBTI-built firmware image runs through the Zig core" {
    try std.testing.expect(std.mem.indexOf(u8, pacbti_image, &.{ 0xAF, 0xF3, 0x0D, 0x80 }) != null);
    try std.testing.expect(std.mem.indexOf(u8, pacbti_image, &.{ 0xAF, 0xF3, 0x0F, 0x80 }) != null);
    try std.testing.expect(std.mem.indexOf(u8, pacbti_image, &.{ 0xAF, 0xF3, 0x2D, 0x80 }) != null);

    const image = try elf.Image.init(pacbti_image);
    var store = try Store.init(null);
    defer store.deinit();
    var segment_index: u16 = 0;
    while (segment_index < image.segmentCount()) : (segment_index += 1) {
        const segment = image.loadSegment(segment_index) orelse continue;
        try put(&store, segment.paddr, segment.bytes);
    }

    var output: [128]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&output);
    var retired: u64 = 0;
    const vector_base = image.vectorBase() orelse return error.MissingVectorTable;
    var periph = ra8.chip.periph.registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    const status = try boot.start(&stream, .zig, .{ .store = &store }, &periph, vector_base, 100, &retired, .{});
    try std.testing.expectEqual(@as(u8, 0), status);
    try std.testing.expectEqual(@as(u64, 100), retired);
    try std.testing.expectEqual(@as(u32, 0x247), std.mem.readInt(u32, store.span(memmap.sram_base, 4).?[0..4], .little));
    try std.testing.expect(std.mem.startsWith(u8, stream.buffered(), "zig core: ran 100 instructions clean"));
}

/// Reset branches to an even address with UsageFault disabled; HardFault
/// spins. movs r0, #0 ; bx r0 ; then b . as the NMI and HardFault handler.
fn loadEvenBranch(store: *Store) !void {
    const base = memmap.sram_base;
    var image: [0x16]u8 = undefined;
    std.mem.writeInt(u32, image[0..4], base + 0x1000, .little);
    std.mem.writeInt(u32, image[4..8], (base + 0x10) | 1, .little);
    std.mem.writeInt(u32, image[8..12], (base + 0x14) | 1, .little);
    std.mem.writeInt(u32, image[12..16], (base + 0x14) | 1, .little);
    @memcpy(image[0x10..0x16], &[_]u8{ 0x00, 0x20, 0x00, 0x47, 0xFE, 0xE7 });
    try put(store, base, &image);
}

test "a board run that took INVSTATE reports CFSR and HFSR.FORCED (RA8EMU-394)" {
    var store = try Store.init(null);
    defer store.deinit();
    try loadEvenBranch(&store);
    var buf: [256]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buf);
    var periph = ra8.chip.periph.registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    _ = try boot.runOnBoard(&stream, .{ .store = &store }, &periph, memmap.sram_base, 50, null, .{});
    const line = "faults: CFSR 0x00020000 invstate, HFSR 0x40000000 forced, SFSR 0x00000000\n";
    std.testing.expect(std.mem.indexOf(u8, stream.buffered(), line) != null) catch |err| {
        std.debug.print("report was: {s}\n", .{stream.buffered()});
        return err;
    };
}

/// A boundary that asks for one reset at its first close, the way the
/// watchdog's underflow does through the board.
const Kick = struct {
    reboot: *ra8.chip.core.reboot.Reboot,
    closes: u32 = 0,

    fn boundary(self: *Kick) boot.Boundary {
        return .{ .context = self, .widthFn = widthOf, .closeFn = closeOf, .reboot = self.reboot };
    }

    fn widthOf(_: *anyopaque) u32 {
        return 3;
    }

    fn closeOf(context: *anyopaque, _: u32) anyerror!void {
        const self: *Kick = @ptrCast(@alignCast(context));
        self.closes += 1;
        if (self.closes == 1) self.reboot.requested = true;
    }
};

test "a reset asked for at a boundary brings the zig core back up on its reset vector" {
    var store = try Store.init(null);
    defer store.deinit();
    // bf00 nop at +8, then e7fe b . at +10.
    const base = memmap.sram_base;
    var image: [12]u8 = undefined;
    std.mem.writeInt(u32, image[0..4], base + 0x1000, .little);
    std.mem.writeInt(u32, image[4..8], (base + 8) | 1, .little);
    @memcpy(image[8..12], &[_]u8{ 0x00, 0xBF, 0xFE, 0xE7 });
    try put(&store, base, &image);
    var reboot: ra8.chip.core.reboot.Reboot = .{ .vector_base = base };
    var kick: Kick = .{ .reboot = &reboot };
    var ran: u64 = 0;
    var buf: [256]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buf);
    var periph = ra8.chip.periph.registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    const status = try boot.runOnBoard(&stream, .{ .store = &store }, &periph, base, 3, &ran, .{ .boundary = kick.boundary() });
    try std.testing.expectEqual(@as(u8, 0), status);
    try std.testing.expectEqual(@as(u32, 1), reboot.performed);
    try std.testing.expect(!reboot.requested);
    // The stretch ended on `b .` at +10; the reset put it back at +8, and
    // the instructions it ran before the reset are still counted.
    try std.testing.expectEqual(@as(u64, 3), ran);
    try std.testing.expect(std.mem.indexOf(u8, stream.buffered(), "pc 0x22000008") != null);
}

/// Records what the snapshot hook saw (RA8EMU-695, RA8EMU-700).
const Probe = struct {
    start_retired: u64 = 0,
    owed_in: u32 = 0,
    loaded: bool = false,
    saved_retired: ?u64 = null,
    saved_pc: u32 = 0,
    saved_owed: u32 = 0,

    fn load(context: *anyopaque, core: *ra8.chip.core.cpu.cpu.Cpu) anyerror!u32 {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.loaded = core.retired == 0;
        core.retired = self.start_retired;
        return self.owed_in;
    }

    fn save(context: *anyopaque, core: *const ra8.chip.core.cpu.cpu.Cpu, owed: u32) anyerror!void {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.saved_retired = core.retired;
        self.saved_pc = core.regs.pc;
        self.saved_owed = owed;
    }

    fn hook(self: *Probe) boot.Snapshot {
        return .{ .context = self, .loadFn = load, .saveFn = save };
    }
};

/// Runs `loadSpin` for `budget` on a board with a boundary of `edges`.
fn runOwed(probe: *Probe, edges: *Edges, budget: u64) !void {
    var store = try Store.init(null);
    defer store.deinit();
    try loadSpin(&store);
    var ran: u64 = 0;
    var buf: [128]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buf);
    var periph = ra8.chip.periph.registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    _ = try boot.runOnBoard(&stream, .{ .store = &store }, &periph, memmap.sram_base, budget, &ran, .{ .boundary = edges.boundary(), .snapshot = probe.hook() });
}

test "a run that saves holds the stretch its budget cut short, saves what it owes, then closes it" {
    var probe: Probe = .{};
    var edges: Edges = .{ .width = 4 };
    try runOwed(&probe, &edges, 10);
    try std.testing.expectEqual(@as(u32, 2), probe.saved_owed);
    try std.testing.expectEqual(@as(u32, 3), edges.closes);
    try std.testing.expectEqual(@as(u64, 10), edges.charged);
}

test "a loaded run starts its first stretch as far in as the saved run owed" {
    var probe: Probe = .{ .owed_in = 2 };
    var edges: Edges = .{ .width = 4 };
    try runOwed(&probe, &edges, 6);
    try std.testing.expectEqual(@as(u32, 0), probe.saved_owed);
    try std.testing.expectEqual(@as(u32, 2), edges.closes);
    try std.testing.expectEqual(@as(u64, 8), edges.charged);
}

test "the snapshot hook loads after reset and saves once the budget is spent" {
    var store = try Store.init(null);
    defer store.deinit();
    try loadSpin(&store);
    var probe: Probe = .{ .start_retired = 1000 };
    var ran: u64 = 0;
    var buf: [128]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buf);
    var periph = ra8.chip.periph.registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    const status = try boot.runOnBoard(&stream, .{ .store = &store }, &periph, memmap.sram_base, 10, &ran, .{ .snapshot = probe.hook() });
    try std.testing.expectEqual(@as(u8, 0), status);
    try std.testing.expect(probe.loaded);
    try std.testing.expectEqual(@as(u64, 1010), probe.saved_retired.?);
    try std.testing.expectEqual(@as(u64, 1010), ran);
    try std.testing.expectEqual(memmap.sram_base + 8, probe.saved_pc);
}

test "a run with no snapshot hook is unchanged" {
    var store = try Store.init(null);
    defer store.deinit();
    try loadSpin(&store);
    var ran: u64 = 0;
    var buf: [128]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buf);
    var periph = ra8.chip.periph.registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    _ = try boot.runOnBoard(&stream, .{ .store = &store }, &periph, memmap.sram_base, 10, &ran, .{});
    try std.testing.expectEqual(@as(u64, 10), ran);
}
