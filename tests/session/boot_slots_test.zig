//! Boot-slot reader over a fake MRAM staged the way stage_slot_image.py
//! lays a slot out: body at the base, 32-byte header in the last page.
const std = @import("std");
const ra8 = @import("ra8");
const boot_slots = ra8.session.boot_slots;
const layout = boot_slots.layout;

const trigger_at: u32 = 0x220F_FF00;
const mram_size = 0x0010_0000;

const Mram = struct {
    bytes: []u8,
    trigger: [4]u8 = .{ 0, 0, 0, 0 },

    fn init() !Mram {
        const bytes = try std.testing.allocator.alloc(u8, mram_size);
        @memset(bytes, 0xFF);
        return .{ .bytes = bytes };
    }

    fn deinit(self: *Mram) void {
        std.testing.allocator.free(self.bytes);
    }

    pub fn read(self: *const Mram, address: u32, into: []u8) !void {
        if (address == trigger_at and into.len == 4) {
            @memcpy(into, &self.trigger);
            return;
        }
        if (address < layout.mram_base or address - layout.mram_base + into.len > self.bytes.len)
            return error.Unmapped;
        @memcpy(into, self.bytes[address - layout.mram_base ..][0..into.len]);
    }

    fn stage(self: *Mram, which: boot_slots.Which, seq: u32, len: u32, corrupt: bool) void {
        const at = boot_slots.baseOf(which) - layout.mram_base;
        const body = self.bytes[at..][0..len];
        for (body, 0..) |*byte, i| byte.* = @truncate(i *% 31 +% seq);
        const crc = std.hash.Crc32.hash(body);
        const fields = [_]u32{ layout.header_magic, seq, len, crc, layout.run_base, 0, 0, 0 };
        const header = self.bytes[at + layout.header_offset ..][0..layout.header_size];
        for (fields, 0..) |field, i| std.mem.writeInt(u32, header[i * 4 ..][0..4], field, .little);
        if (corrupt) body[len / 2] ^= 0x01;
    }

    fn askDfu(self: *Mram) void {
        std.mem.writeInt(u32, &self.trigger, layout.trigger_magic, .little);
    }
};

test "the body CRC is the firmware's IEEE CRC32" {
    try std.testing.expectEqual(@as(u32, 0xCBF4_3926), std.hash.Crc32.hash("123456789"));
    try std.testing.expectEqual(@as(u32, 0xE8B7_BE43), std.hash.Crc32.hash("a"));
}

test "both valid: the higher sequence boots, from either slot" {
    var mram = try Mram.init();
    defer mram.deinit();
    mram.stage(.a, 3, 0x1000, false);
    mram.stage(.b, 4, 0x2040, false);
    var report = try boot_slots.read(&mram, trigger_at);
    try std.testing.expectEqual(boot_slots.Action.boot_b, report.action);
    try std.testing.expectEqual(boot_slots.Trigger.clear, report.trigger);
    try std.testing.expect(report.a.valid and report.b.valid and report.b.entry_ok);
    try std.testing.expectEqual(layout.slot_b_base, report.booted().?.base);
    try std.testing.expectEqual(layout.run_base, report.run_base);
    mram.stage(.a, 9, 0x1000, false);
    report = try boot_slots.read(&mram, trigger_at);
    try std.testing.expectEqual(boot_slots.Action.boot_a, report.action);
}

test "a tie goes to slot A" {
    var mram = try Mram.init();
    defer mram.deinit();
    mram.stage(.a, 7, 0x0800, false);
    mram.stage(.b, 7, 0x0800, false);
    const report = try boot_slots.read(&mram, trigger_at);
    try std.testing.expectEqual(boot_slots.Action.boot_a, report.action);
}

test "a newer slot with a bad CRC loses to the older valid one" {
    var mram = try Mram.init();
    defer mram.deinit();
    mram.stage(.a, 2, 0x0400, false);
    mram.stage(.b, 3, 0x0400, true);
    const report = try boot_slots.read(&mram, trigger_at);
    try std.testing.expectEqual(boot_slots.Action.boot_a, report.action);
    try std.testing.expect(report.b.magic_ok and report.b.length_ok and !report.b.valid);
    try std.testing.expect(report.b.crc.? != report.b.header.img_crc32);
}

test "the trigger word keeps the board in DFU even with valid slots" {
    var mram = try Mram.init();
    defer mram.deinit();
    mram.stage(.a, 1, 0x0400, false);
    mram.stage(.b, 2, 0x0400, false);
    mram.askDfu();
    const report = try boot_slots.read(&mram, trigger_at);
    try std.testing.expectEqual(boot_slots.Trigger.set, report.trigger);
    try std.testing.expectEqual(boot_slots.Action.dfu, report.action);
    try std.testing.expect(report.booted() == null);
}

test "two erased slots stay in DFU, and no trigger address reads unknown" {
    var mram = try Mram.init();
    defer mram.deinit();
    const report = try boot_slots.read(&mram, null);
    try std.testing.expectEqual(boot_slots.Action.dfu, report.action);
    try std.testing.expectEqual(boot_slots.Trigger.unknown, report.trigger);
    try std.testing.expect(!report.a.length_ok and report.a.crc == null and !report.a.magic_ok);
}

test "a full-size image is checked to its last body byte" {
    var mram = try Mram.init();
    defer mram.deinit();
    mram.stage(.b, 5, layout.image_max, false);
    const report = try boot_slots.read(&mram, null);
    try std.testing.expectEqual(boot_slots.Action.boot_b, report.action);
    mram.bytes[layout.slot_b_base - layout.mram_base + layout.image_max - 1] ^= 0x80;
    const torn = try boot_slots.read(&mram, null);
    try std.testing.expectEqual(boot_slots.Action.dfu, torn.action);
}
