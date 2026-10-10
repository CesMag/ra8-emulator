//! The PI4IOE5V6408 I/O port expander (U15) on the EK-RA8D2's system I2C bus,
//! 7-bit address 0x43.
//!
//! The part is a register file behind an auto-incrementing pointer: a write
//! puts the pointer down first and then payload bytes, a read serves from
//! wherever the pointer stands, and a STOP ends the transfer so the next one
//! names its own register.
const std = @import("std");
const bus = @import("ra8_chip").periph.riic.bus;

pub const address: u7 = 0x43;

/// The register file this model carries (PI4IOE5V6408 datasheet Table 2:
/// 0x00 chip id, 0x01 device id and control, through 0x0F).
pub const file = struct {
    pub const count: usize = 0x10;
    pub const device_id: usize = 0x01;
    /// Device-ID reset default, the value a probe reads back to know the part
    /// is there.
    pub const device_id_value: u8 = 0xA0;
};

pub const Expander = struct {
    registers: [file.count]u8 = blk: {
        var reset = @as([file.count]u8, @splat(0));
        reset[file.device_id] = file.device_id_value;
        break :blk reset;
    },
    /// Where the pointer stands, and whether this transfer has set it yet.
    pointer: u8 = 0,
    pointed: bool = false,
    /// Register writes the controller landed.
    writes: u32 = 0,
    /// Pointer bytes naming a register the part does not have. dev took the
    /// byte modulo the file size, so a driver aiming at 0x25 quietly wrote
    /// 0x05 and read back exactly what it wrote. Refused here instead.
    bad_pointer: u32 = 0,
    /// Payload bytes dropped because the pointer was never accepted.
    dropped: u32 = 0,

    pub fn quiet(self: *const Expander) bool {
        return self.writes == 0 and self.bad_pointer == 0 and self.dropped == 0;
    }

    pub fn write(self: *Expander, byte: u8) void {
        if (!self.pointed) {
            if (byte >= file.count) {
                self.bad_pointer += 1;
                return;
            }
            self.pointer = byte;
            self.pointed = true;
            return;
        }
        self.registers[self.pointer] = byte;
        self.pointer = @intCast((@as(usize, self.pointer) + 1) % file.count);
        self.writes += 1;
    }

    /// Serve from the pointer on, wrapping inside the file the way the part's
    /// auto-increment does. A read with no pointer set starts at 0x00, which
    /// is what the part does after a bare address byte.
    pub fn read(self: *Expander, into: []u8) usize {
        const served = @min(into.len, file.count);
        for (into[0..served], 0..) |*slot, i| {
            slot.* = self.registers[(@as(usize, self.pointer) + i) % file.count];
        }
        return served;
    }

    pub fn stop(self: *Expander) void {
        self.pointed = false;
    }

    pub fn device(self: *Expander) bus.Device {
        return .{
            .address = address,
            .context = self,
            .writeFn = writeThunk,
            .readFn = readThunk,
            .stopFn = stopThunk,
        };
    }
};

fn writeThunk(context: *anyopaque, byte: u8) void {
    const self: *Expander = @ptrCast(@alignCast(context));
    self.write(byte);
}

fn readThunk(context: *anyopaque, into: []u8) usize {
    const self: *Expander = @ptrCast(@alignCast(context));
    return self.read(into);
}

fn stopThunk(context: *anyopaque) void {
    const self: *Expander = @ptrCast(@alignCast(context));
    self.stop();
}
