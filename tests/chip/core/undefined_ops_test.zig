//! The sweep for encodings the architecture leaves undefined.
const std = @import("std");
const ra8 = @import("ra8");
const undefined_ops = ra8.chip.core.undefined_ops;
const elf = ra8.board.image.elf;
const imageWith = @import("undefined_image.zig").imageWith;

/// The program counter shifted into an AND: and.w r3, r2, pc, lsl #2.
const orrs_pc = [2]u16{ 0xEA02, 0x038F };

/// The same shape the compiler should have emitted: orr.w r3, r3, r2, lsr #30.
const orr_clean = [2]u16{ 0xEA43, 0x7392 };

test "the program counter as a shifted operand is undefined" {
    try std.testing.expect(undefined_ops.shiftedPc(orrs_pc[0], orrs_pc[1]));
}

test "the same instruction on a real register is not" {
    try std.testing.expect(!undefined_ops.shiftedPc(orr_clean[0], orr_clean[1]));
}

test "a wider shift of the program counter is undefined too" {
    // and.w r3, r2, pc, lsl #3.
    try std.testing.expect(undefined_ops.shiftedPc(0xEA02, 0x03CF));
}

test "an Armv8.1-M long shift in the same space is defined" {
    // The encoding that cost four sessions: lsll r2, r3, #2, which Armv7-M
    // reads as orrs.w r3, r2, pc, lsl #2. Then lsll r2, r3, r4.
    try std.testing.expect(!undefined_ops.shiftedPc(0xEA52, 0x038F));
    try std.testing.expect(!undefined_ops.shiftedPc(0xEA52, 0x430D));
}

test "a branch that happens to end in fifteen is not this class" {
    // Bit 15 of the second halfword is set on a branch, never on this class.
    try std.testing.expect(!undefined_ops.shiftedPc(0xF000, 0xB80F));
}

test "a coprocessor encoding is not this class" {
    try std.testing.expect(!undefined_ops.shiftedPc(0xED2F, 0x0B0F));
}

test "a sixteen bit halfword is not the start of a wide instruction" {
    try std.testing.expect(!undefined_ops.isWide(0x4610));
    try std.testing.expect(undefined_ops.isWide(0xEA52));
}

test "the list stops but the count does not" {
    var found = undefined_ops.Found{};
    for (0..undefined_ops.limits.listed + 3) |step| {
        const site = undefined_ops.Site{ .address = @intCast(step), .encoding = 0 };
        // add is private, so go through a sweep-shaped path: write directly.
        if (found.count < undefined_ops.limits.listed) found.sites[found.count] = site;
        found.count += 1;
    }
    try std.testing.expectEqual(undefined_ops.limits.listed + 3, found.count);
    try std.testing.expectEqual(undefined_ops.limits.listed, found.listed().len);
}

test "a sweep names the site at its own address" {
    // mov r0, r2 ; and.w r3, r2, pc, lsl #2 ; mov r1, r3
    const code = [_]u8{ 0x10, 0x46, 0x02, 0xEA, 0x8F, 0x03, 0x19, 0x46 };
    var buffer: [256]u8 = undefined;
    const found = sweep(imageWith(&buffer, &code, 0x02007000));
    try std.testing.expectEqual(@as(usize, 1), found.count);
    try std.testing.expectEqual(@as(u32, 0x02007002), found.listed()[0].address);
    try std.testing.expectEqual(@as(u32, 0xEA02038F), found.listed()[0].encoding);
}

test "a clean image sweeps to nothing" {
    const code = [_]u8{ 0x10, 0x46, 0x43, 0xEA, 0x92, 0x73, 0x19, 0x46 };
    var buffer: [256]u8 = undefined;
    const found = sweep(imageWith(&buffer, &code, 0x02007000));
    try std.testing.expectEqual(@as(usize, 0), found.count);
}

test "a non executable segment is not swept" {
    const code = [_]u8{ 0x02, 0xEA, 0x8F, 0x03 };
    var buffer: [256]u8 = undefined;
    var image = imageWith(&buffer, &code, 0x02007000);
    const at = @as(usize, image.header().e_phoff);
    const ph = std.mem.bytesAsValue(elf.ProgramHeader, buffer[at..][0..@sizeOf(elf.ProgramHeader)]);
    ph.p_flags = 4;
    image = elf.Image.init(&buffer) catch unreachable;
    try std.testing.expectEqual(@as(usize, 0), sweep(image).count);
}

test "a site starts with no arrivals" {
    var found = undefined_ops.Found{};
    found.sites[0] = .{ .address = 0x0200_7498, .encoding = 0xEA02038F };
    found.count = 1;
    try std.testing.expectEqual(@as(usize, 0), found.sitesRun());
    try std.testing.expectEqual(@as(u64, 0), found.arrivals());
}

test "an arrival is counted against its own site" {
    var found = undefined_ops.Found{};
    found.sites[0] = .{ .address = 0x0200_7498, .encoding = 0xEA02038F };
    found.sites[1] = .{ .address = 0x0200_8984, .encoding = 0xEA02038F };
    found.count = 2;
    found.kept()[1].runs += 3;
    try std.testing.expectEqual(@as(usize, 1), found.sitesRun());
    try std.testing.expectEqual(@as(u64, 3), found.arrivals());
    try std.testing.expectEqual(@as(u32, 0), found.kept()[0].runs);
}

test "kept holds every site the report does not list" {
    var found = undefined_ops.Found{};
    var index: usize = 0;
    while (index < 10) : (index += 1) {
        found.sites[index] = .{ .address = @intCast(0x0200_0000 + index * 4), .encoding = 0xEA02038F };
    }
    found.count = 10;
    try std.testing.expectEqual(@as(usize, 10), found.kept().len);
    try std.testing.expectEqual(@as(usize, undefined_ops.limits.listed), found.listed().len);
}

test "a kept site does not stop the run by default" {
    var found = undefined_ops.Found{};
    found.sites[0] = .{ .address = 0x0200_0100, .encoding = 0xEA02_038F };
    found.count = 1;
    try std.testing.expect(!found.sites[0].stop);
    found.sites[0].runs = 1;
    try std.testing.expect(found.stoppedAt() == null);
}

test "stopOnRun arms every kept site" {
    var found = undefined_ops.Found{};
    found.sites[0] = .{ .address = 0x0200_0100, .encoding = 0xEA02_038F };
    found.sites[1] = .{ .address = 0x0200_0200, .encoding = 0xEA02_03CF };
    found.count = 2;
    found.stopOnRun();
    for (found.kept()) |site| try std.testing.expect(site.stop);
}

test "an armed site that never ran stopped nothing" {
    var found = undefined_ops.Found{};
    found.sites[0] = .{ .address = 0x0200_0100, .encoding = 0xEA02_038F };
    found.count = 1;
    found.stopOnRun();
    try std.testing.expect(found.stoppedAt() == null);
}

test "the first armed site that ran is the one that stopped the run" {
    var found = undefined_ops.Found{};
    found.sites[0] = .{ .address = 0x0200_0100, .encoding = 0xEA02_038F };
    found.sites[1] = .{ .address = 0x0200_0200, .encoding = 0xEA02_03CF };
    found.count = 2;
    found.stopOnRun();
    found.sites[1].runs = 1;
    const at = found.stoppedAt() orelse return error.TestExpectedSite;
    try std.testing.expectEqual(@as(u32, 0x0200_0200), at.address);
}

test "a site past the watch limit can neither be armed nor stop anything" {
    var found = undefined_ops.Found{};
    for (0..undefined_ops.limits.watched) |index| {
        found.sites[index] = .{
            .address = @intCast(0x0200_0000 + index * 4),
            .encoding = 0xEA02_038F,
        };
    }
    found.count = undefined_ops.limits.watched + 3;
    found.stopOnRun();
    try std.testing.expectEqual(undefined_ops.limits.watched, found.kept().len);
    try std.testing.expect(found.stoppedAt() == null);
}

fn sweep(image: elf.Image) undefined_ops.Found {
    const loaded = ra8.board.image.load.read(image) catch unreachable;
    return undefined_ops.sweep(loaded.image());
}
