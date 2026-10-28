//! Covers src/session/history/state_memory.zig: two memory sections are
//! compared as held, except where either image loaded its own read-only
//! bytes. A rebuilt image's code and constants are not a difference; a
//! variable's different initial value is one until both runs have written
//! the same value over it, and then it is not.
const std = @import("std");
const ra8 = @import("ra8");

const memory = ra8.session.history_state_memory;
const elf = ra8.board.image.elf;

const gpa = std.testing.allocator;

const rom_base: u32 = 0x1000;
const flash_copy: u32 = 0x1100;
const ram_base: u32 = 0x2000_0000;

/// A one-region section: the page at offset 0 holds `bytes`, the rest of
/// the 4 KiB region is left out.
fn section(out: *std.ArrayList(u8), base: u32, bytes: []const u8) !void {
    for ([_]u32{ 1, base, memory.page, 1, 0 }) |word| try out.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeToLittle(u32, word)));
    var page: [memory.page]u8 = @splat(0);
    @memcpy(page[0..bytes.len], bytes);
    try out.appendSlice(gpa, &page);
}

/// An ELF with a read-only code segment at `rom_base` and an initialised
/// data segment that runs in RAM and is loaded at `flash_copy`.
fn image(out: *std.ArrayList(u8), code: u8, data: u8) !void {
    var head = std.mem.zeroes(elf.Header);
    head.magic = "\x7fELF".*;
    head.class = 1;
    head.data = 1;
    head.e_machine = elf.em_arm;
    head.e_phoff = @sizeOf(elf.Header);
    head.e_phentsize = @sizeOf(elf.ProgramHeader);
    head.e_phnum = 2;
    const body = @sizeOf(elf.Header) + 2 * @sizeOf(elf.ProgramHeader);
    const loads = [_]elf.ProgramHeader{
        .{ .p_type = elf.pt_load, .p_offset = body, .p_vaddr = rom_base, .p_paddr = rom_base, .p_filesz = 4, .p_memsz = 4, .p_flags = 5, .p_align = 4 },
        .{ .p_type = elf.pt_load, .p_offset = body + 4, .p_vaddr = ram_base, .p_paddr = flash_copy, .p_filesz = 4, .p_memsz = 4, .p_flags = 6, .p_align = 4 },
    };
    try out.appendSlice(gpa, std.mem.asBytes(&head));
    for (loads) |load| try out.appendSlice(gpa, std.mem.asBytes(&load));
    try out.appendSlice(gpa, &[_]u8{ code, code, code, code, data, data, data, data });
}

const Sides = struct {
    original: std.ArrayList(u8) = .empty,
    rebuilt: std.ArrayList(u8) = .empty,

    fn deinit(self: *Sides) void {
        self.original.deinit(gpa);
        self.rebuilt.deinit(gpa);
    }
};

/// The first difference between two runs' memory, and whether they hash
/// alike, with each run's image built from its code and initial data bytes.
fn compare(base: u32, left: []const u8, right: []const u8, code: [2]u8, data: [2]u8) !struct { spot: ?memory.Spot, same_hash: bool } {
    var images: Sides = .{};
    defer images.deinit();
    try image(&images.original, code[0], data[0]);
    try image(&images.rebuilt, code[1], data[1]);
    const mask: memory.Mask = .{ .a = try elf.Image.init(images.original.items), .b = try elf.Image.init(images.rebuilt.items) };
    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(gpa);
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    try section(&a, base, left);
    try section(&b, base, right);
    const parsed_a = try memory.parse(a.items);
    const parsed_b = try memory.parse(b.items);
    var ha = std.crypto.hash.Blake3.init(.{});
    var hb = std.crypto.hash.Blake3.init(.{});
    memory.hash(&ha, parsed_a, mask);
    memory.hash(&hb, parsed_b, mask);
    var da: [16]u8 = undefined;
    var db: [16]u8 = undefined;
    ha.final(&da);
    hb.final(&db);
    return .{ .spot = memory.firstDifference(parsed_a, parsed_b, mask), .same_hash = std.mem.eql(u8, &da, &db) };
}

test "a rebuilt image's own code and flash copy are not a difference" {
    const code = try compare(rom_base, &.{ 1, 1, 1, 1 }, &.{ 2, 2, 2, 2 }, .{ 1, 2 }, .{ 0, 0 });
    try std.testing.expectEqual(@as(?memory.Spot, null), code.spot);
    try std.testing.expect(code.same_hash);
    const copy = try compare(flash_copy, &.{ 7, 7, 7, 7 }, &.{ 8, 8, 8, 8 }, .{ 0, 0 }, .{ 7, 8 });
    try std.testing.expectEqual(@as(?memory.Spot, null), copy.spot);
    try std.testing.expect(copy.same_hash);
}

test "a different initial value of a variable in RAM is a difference" {
    const out = try compare(ram_base, &.{ 5, 0, 0, 0 }, &.{ 6, 0, 0, 0 }, .{ 0, 0 }, .{ 5, 6 });
    try std.testing.expectEqual(memory.Spot{ .address = ram_base, .expected = 5, .actual = 6 }, out.spot.?);
    try std.testing.expect(!out.same_hash);
}

test "an initialiser that both runs wrote the same value over is not a difference" {
    // Original started at 5 and wrote 9; the rebuild started at 6 and wrote 9.
    const out = try compare(ram_base, &.{ 9, 0, 0, 0 }, &.{ 9, 0, 0, 0 }, .{ 0, 0 }, .{ 5, 6 });
    try std.testing.expectEqual(@as(?memory.Spot, null), out.spot);
    try std.testing.expect(out.same_hash);
}

test "two writes that only look alike against their own loads are a difference" {
    // 9 over an initial 5 and 10 over an initial 6 both change the byte by
    // the same XOR; the bytes held are 9 and 10.
    const out = try compare(ram_base, &.{ 9, 0, 0, 0 }, &.{ 10, 0, 0, 0 }, .{ 0, 0 }, .{ 5, 6 });
    try std.testing.expectEqual(memory.Spot{ .address = ram_base, .expected = 9, .actual = 10 }, out.spot.?);
    try std.testing.expect(!out.same_hash);
}
