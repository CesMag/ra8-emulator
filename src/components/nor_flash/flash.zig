//! The octal NOR part behind XSPI0: a configurable array stored inverted so fresh erased flash
//! is demand-zero host memory and mapped accesses allocate nothing.
const std = @import("std");
const xspi_nor = @import("ra8_chip").periph.xspi_nor;
const mapped = @import("ra8_chip").core.cpu.mapped;
const lines = @import("lines.zig");

pub const part = struct {
    pub const size: u32 = 0x400_0000;
    pub const sector_len: u32 = 0x1000;
    pub const erased: u8 = 0xFF;
    pub const jedec = [3]u8{ 0x9D, 0x5A, 0x1A };
    pub const page_len: u32 = 0x100;

    pub fn sectorOf(address: u32) u32 {
        return address / sector_len;
    }

    pub fn pageOf(address: u32) u32 {
        return address & ~(page_len - 1);
    }

    pub fn programStep(address: u32, index: u32) u32 {
        return pageOf(address) + ((address +% index) % page_len);
    }

    pub fn holds(address: u32, len: u32) bool {
        return @as(u64, address) + len <= size;
    }
    pub fn crossesPage(address: u32, len: u32) bool {
        if (len == 0) return false;
        return (address % page_len) + len > page_len;
    }
};

pub const Flash = struct {
    allocator: std.mem.Allocator,
    capacity: u32 = part.size,
    inverted: []u8 = &.{},
    dirty: []u8 = &.{},

    pub fn init(allocator: std.mem.Allocator) Flash {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Flash) void {
        if (self.inverted.len != 0) self.allocator.free(self.inverted);
        if (self.dirty.len != 0) self.allocator.free(self.dirty);
        self.inverted = &.{};
        self.dirty = &.{};
    }

    /// Select the profile capacity and establish all access storage before a
    /// CPU or bus initiator can touch the part.
    pub fn resize(self: *Flash, capacity: u32) !void {
        if (self.capacity == capacity and self.inverted.len != 0) return;
        const bytes = try self.allocator.alloc(u8, capacity);
        errdefer self.allocator.free(bytes);
        const sectors = capacity / part.sector_len;
        const bits = try self.allocator.alloc(u8, (sectors + 7) / 8);
        if (self.inverted.len != 0) self.allocator.free(self.inverted);
        if (self.dirty.len != 0) self.allocator.free(self.dirty);
        @memset(bytes, 0);
        @memset(bits, 0);
        self.capacity = capacity;
        self.inverted = bytes;
        self.dirty = bits;
    }

    pub fn holds(self: *const Flash, address: u32, len: u32) bool {
        return @as(u64, address) + len <= self.capacity;
    }

    pub fn live(self: *const Flash) u32 {
        var total: u32 = 0;
        for (self.dirty) |bits| total += @popCount(bits);
        return total;
    }

    pub fn byte(self: *const Flash, address: u32) u8 {
        if (address >= self.capacity or self.inverted.len == 0) return part.erased;
        return ~self.inverted[address];
    }

    /// JEDEC manufacturer/type plus the byte-capacity exponent for this
    /// profile's power-of-two part.
    pub fn jedecId(self: *const Flash) [3]u8 {
        return .{ part.jedec[0], part.jedec[1], @intCast(std.math.log2_int(u32, self.capacity)) };
    }

    pub fn jedecWord(self: *const Flash) u24 {
        const id = self.jedecId();
        return std.mem.readInt(u24, &id, .little);
    }

    pub fn program(self: *Flash, address: u32, value: u8) !void {
        if (address >= self.capacity) return;
        try self.ensure();
        const next = self.inverted[address] | ~value;
        if (next == self.inverted[address]) return;
        self.inverted[address] = next;
        self.mark(part.sectorOf(address), true);
    }

    pub fn erase(self: *Flash, address: u32) void {
        if (address >= self.capacity or self.inverted.len == 0) return;
        const first = part.sectorOf(address) * part.sector_len;
        @memset(self.inverted[first..][0..part.sector_len], 0);
        self.mark(part.sectorOf(address), false);
    }

    pub fn reset(self: *Flash) void {
        if (self.inverted.len != 0) @memset(self.inverted, 0);
        if (self.dirty.len != 0) @memset(self.dirty, 0);
    }

    pub fn readMapped(self: *const Flash, address: u32, into: []u8) bool {
        if (!self.holds(address, @intCast(into.len))) return false;
        for (into, 0..) |*value, index| value.* = self.byte(address + @as(u32, @intCast(index)));
        return true;
    }

    pub fn writeMapped(self: *Flash, address: u32, bytes: []const u8) !bool {
        if (!self.holds(address, @intCast(bytes.len))) return false;
        try self.ensure();
        for (bytes, 0..) |value, index| try self.program(address + @as(u32, @intCast(index)), value);
        return true;
    }

    pub fn sectorDirty(self: *const Flash, index: u32) bool {
        if (index / 8 >= self.dirty.len) return false;
        return self.dirty[index / 8] & (@as(u8, 1) << @intCast(index % 8)) != 0;
    }

    pub fn readSector(self: *const Flash, index: u32, out: *[part.sector_len]u8) void {
        const first = index * part.sector_len;
        for (out, 0..) |*value, offset| value.* = self.byte(first + @as(u32, @intCast(offset)));
    }

    pub fn loadSector(self: *Flash, index: u32, bytes: *const [part.sector_len]u8) !void {
        if (index >= self.capacity / part.sector_len) return error.OutOfMemory;
        try self.ensure();
        const first = index * part.sector_len;
        for (bytes, 0..) |value, offset| self.inverted[first + offset] = ~value;
        self.mark(index, true);
    }

    /// The command-engine contract XSPI0 calls. The board plugs this in
    /// once the part is at its final address.
    pub fn nor(self: *Flash) xspi_nor.Nor {
        return lines.nor(self);
    }

    /// The mapped-window contract the memory store calls.
    pub fn window(self: *Flash) mapped.Mapped {
        return lines.window(self);
    }

    fn ensure(self: *Flash) !void {
        if (self.inverted.len == 0) try self.resize(self.capacity);
    }

    fn mark(self: *Flash, index: u32, set: bool) void {
        const bit = @as(u8, 1) << @intCast(index % 8);
        if (set) self.dirty[index / 8] |= bit else self.dirty[index / 8] &= ~bit;
    }
};
