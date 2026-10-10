//! The FPU conversion corpus image (RA8EMU-143): tests/fixtures/fpu/fp_cvt.elf
//! runs every scalar float/integer/precision conversion and round-to-integral
//! op the Cortex-M85 has on the Zig core. Expected words come from the
//! DDI0553 pseudocode (see fp_cvt_vectors.zig), not from the core.
const std = @import("std");
const ra8 = @import("ra8");
const memmap = ra8.chip.core.memmap;
const boot = ra8.chip.core.cpu.boot;
const elf = ra8.board.image.elf;
const Store = ra8.chip.core.cpu.memory.store.Store;
const Guest = ra8.chip.core.cpu.memory.guest.Guest;
const vectors = @import("fp_cvt_vectors.zig");

const image_bytes = @embedFile("../../../fixtures/fpu/fp_cvt.elf");
const results = memmap.sram_base + 0x100;

test "the FPU conversion corpus image runs bit-exact on the Zig core" {
    const image = try elf.Image.init(image_bytes);
    var store = try Store.init(null);
    defer store.deinit();
    const core: Guest = .{ .store = &store };
    var segment_index: u16 = 0;
    while (segment_index < image.segmentCount()) : (segment_index += 1) {
        const segment = image.loadSegment(segment_index) orelse continue;
        try core.write(segment.paddr, segment.bytes);
    }
    var output: [128]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&output);
    var retired: u64 = 0;
    const vector_base = image.vectorBase() orelse return error.MissingVectorTable;
    var periph = ra8.chip.periph.registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    const status = try boot.start(&stream, .zig, core, &periph, vector_base, 60_000, &retired, .{});
    try std.testing.expectEqual(@as(u8, 0), status);
    for (vectors.words, 0..) |want, index| {
        const got = try core.readWord(results + @as(u32, @intCast(index)) * 4);
        std.testing.expectEqual(want, got) catch |err| {
            std.debug.print("word {d}: want 0x{X:0>8} got 0x{X:0>8}\n", .{ index, want, got });
            return err;
        };
    }
}
