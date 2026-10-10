//! Ancillary Ethernet setup registers touched by the GWCA open path.
//!
//! The firmware programs these configuration and interrupt words before it
//! starts the gateway. The modeled MAC, gateway, forwarding and timer blocks
//! own behavior; this bank only retains setup words with no modeled side effect.
const periph = @import("../registry.zig");
const lanes = @import("../lanes.zig");

pub const addresses = [_]u32{
    0x403C_D004, 0x403C_D010, 0x403C_D020,
    0x403C_D080, 0x403C_D08C, 0x403C_D184,
    0x403C_D188, 0x403C_D204, 0x403C_D208,
    0x403C_D214, 0x403C_D218, 0x403C_D224,
    0x403C_D228, 0x403C_D234, 0x403C_D238,
    0x403C_E008, 0x403C_E00C, 0x403E_1400,
    0x403E_1408,
};

const windows = [_][2]u32{
    .{ 0x403C_D004, 0x7C },
    .{ 0x403C_D080, 0x04 },
    .{ 0x403C_D08C, 0x1B0 },
    .{ 0x403C_E008, 0x08 },
    .{ 0x403E_1400, 0x0C },
};

pub const Bank = struct {
    values: [addresses.len]u32 = @splat(0),
    writes: u32 = 0,

    pub fn read(self: *Bank, address: u32, width: u3) u32 {
        const index = find(address) orelse return 0;
        if (address == 0x403C_E008 or address == 0x403C_E00C) return 0;
        return lanes.part(self.values[index], address & 3, width);
    }

    pub fn write(self: *Bank, address: u32, width: u3, value: u32) void {
        self.writes +%= 1;
        const index = find(address) orelse return;
        if (address == 0x403C_E008 or address == 0x403C_E00C) return;
        self.values[index] = lanes.merge(self.values[index], address & 3, width, value);
    }

    pub fn blocks(self: *Bank) [windows.len]periph.Block {
        var result: [windows.len]periph.Block = undefined;
        for (&result, windows) |*block, window| {
            block.* = .{
                .name = "ETH-SETUP",
                .base = window[0],
                .size = window[1],
                .context = self,
                .readFn = readThunk,
                .writeFn = writeThunk,
            };
        }
        return result;
    }

    pub fn quiet(self: *const Bank) bool {
        return self.writes == 0;
    }
};

fn find(address: u32) ?usize {
    for (addresses, 0..) |at, index| {
        if (address >= at and address < at + 4) return index;
    }
    return null;
}

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Bank = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Bank = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
