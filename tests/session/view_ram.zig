//! A Zig core over a little board memory for the remote-protocol tests:
//! SRAM at its board address and the PPB, where the debug units live.
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const memmap = ra8.chip.core.memmap;
const View = ra8.session.step_hook.core_view.View;

const ppb_base: u32 = 0xE000_0000;

pub const Rig = struct {
    sram: [0x2000]u8 = @splat(0),
    ppb: [0x10000]u8 = @splat(0),
    cpu: Cpu = undefined,

    /// Point the core at this rig's memory, once the rig has its home.
    pub fn wire(self: *Rig) void {
        self.cpu = .{ .bus = .{ .ctx = self, .vtable = &.{ .read = read, .write = write } } };
    }

    pub fn view(self: *Rig) View {
        return .{ .zig = .{ .cpu = &self.cpu } };
    }

    fn window(self: *Rig, address: u32, len: usize) bus.Error![]u8 {
        const end = @as(u64, address) + len;
        if (address >= memmap.sram_base and end <= @as(u64, memmap.sram_base) + self.sram.len) {
            return self.sram[address - memmap.sram_base ..][0..len];
        }
        if (address >= ppb_base and end <= @as(u64, ppb_base) + self.ppb.len) {
            return self.ppb[address - ppb_base ..][0..len];
        }
        return bus.Error.Unmapped;
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Rig = @ptrCast(@alignCast(ctx));
        @memcpy(into, try self.window(address, into.len));
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        const self: *Rig = @ptrCast(@alignCast(ctx));
        @memcpy(try self.window(address, from.len), from);
    }
};
