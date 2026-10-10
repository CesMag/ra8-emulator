//! 1 KiB of RAM at 0x2000_0000 for the exception tests: the vector table at
//! the bottom, code at 0x100, the handler at 0x180, the Process stack top at
//! 0x300 and the Main stack top at 0x400. A page of the System Control Space
//! at 0xE000_E000 holds the NVIC and SCB registers; VTOR there reads zero, so
//! entry falls back to the table the core reset from.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;

pub const base: u32 = 0x2000_0000;
pub const code: u32 = base + 0x100;
pub const handler: u32 = base + 0x180;
pub const psp_top: u32 = base + 0x300;
pub const msp_top: u32 = base + 0x400;
pub const scs: u32 = 0xE000_E000;
pub const scs_ns: u32 = 0xE002_E000;

pub const Ram = struct {
    bytes: [0x400]u8 = @splat(0),
    scs_page: [0x1000]u8 = @splat(0),
    /// The Non-secure alias of the SCS page (RA8EMU-438).
    scs_ns_page: [0x1000]u8 = @splat(0),

    pub fn view(self: *Ram) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn slot(self: *Ram, address: u32, len: usize) bus.Error![]u8 {
        if (address >= scs and address - scs + len <= self.scs_page.len) return self.scs_page[address - scs ..][0..len];
        if (address >= scs_ns and address - scs_ns + len <= self.scs_ns_page.len) return self.scs_ns_page[address - scs_ns ..][0..len];
        if (address < base or address - base + len > self.bytes.len) return bus.Error.Unmapped;
        return self.bytes[address - base ..][0..len];
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        @memcpy(into, try self.slot(address, into.len));
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        @memcpy(try self.slot(address, from.len), from);
    }

    pub fn word(self: *Ram, address: u32) u32 {
        return std.mem.readInt(u32, (self.slot(address, 4) catch unreachable)[0..4], .little);
    }

    pub fn putWord(self: *Ram, address: u32, value: u32) void {
        std.mem.writeInt(u32, (self.slot(address, 4) catch unreachable)[0..4], value, .little);
    }

    pub fn putHalf(self: *Ram, address: u32, value: u16) void {
        std.mem.writeInt(u16, (self.slot(address, 2) catch unreachable)[0..2], value, .little);
    }
};

/// A core reset from the table at `base`, with exception 11 (SVC) aimed at
/// `handler` and the reset vector at `code`.
pub fn boot(ram: *Ram) !Cpu {
    ram.putWord(base, msp_top);
    ram.putWord(base + 4, code | 1);
    ram.putWord(base + 11 * 4, handler | 1);
    var cpu: Cpu = .{ .bus = ram.view() };
    try cpu.reset(base);
    // SystemInit's CPACR write: CP10 and CP11 full access, so FP and MVE
    // run. A test that wants the FPU off clears cpu.fp.cpacr.
    cpu.fp.cpacr = 0x00F0_0000;
    return cpu;
}
