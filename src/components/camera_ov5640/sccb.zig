//! The OV5640 camera sensor's SCCB side, 7-bit address 0x3C.
//!
//! SCCB is I2C with a 16-bit big-endian register pointer and no auto-increment:
//! every transfer names its register. The chip-ID pair is what a driver reads
//! to decide the sensor is there at all, and the handful of output-format
//! registers are the ones firmware writes and then verifies.
//!
//! There is no analog sensor behind this. It answers the probe and remembers
//! configuration; it does not claim the board streams pixels.
const std = @import("std");
const bus = @import("ra8_chip").periph.riic.bus;

pub const address: u7 = 0x3C;

/// The registers this model carries (OV5640 datasheet Ch 4).
pub const reg = struct {
    pub const id_high: u16 = 0x300A;
    pub const id_low: u16 = 0x300B;
    pub const format: u16 = 0x4300;
    pub const isp_mux: u16 = 0x501F;
    pub const test_pattern: u16 = 0x503D;
    /// Chip ID 0x5640, split the way the two registers serve it.
    pub const id_high_value: u8 = 0x56;
    pub const id_low_value: u8 = 0x40;
    pub const pointer_bytes: u8 = 2;
};

pub const Sensor = struct {
    pointer: u16 = 0,
    pointer_bytes: u8 = 0,
    format: u8 = 0,
    isp_mux: u8 = 0,
    test_pattern: u8 = 0,
    /// Writes that landed in a register this model carries.
    writes: u32 = 0,
    /// Writes to a register it does not carry. dev counted these as accepted
    /// and then read the register back as zero, so a driver that verified its
    /// own configuration saw a value it never wrote and could not tell the
    /// difference. Counted apart here and said so in the report.
    unmodelled: u32 = 0,
    /// Chip-ID bytes served, so a run can say the probe happened.
    id_reads: u32 = 0,

    pub fn quiet(self: *const Sensor) bool {
        return self.writes == 0 and self.unmodelled == 0 and self.id_reads == 0;
    }

    pub fn write(self: *Sensor, byte: u8) void {
        if (self.pointer_bytes < reg.pointer_bytes) {
            if (self.pointer_bytes == 0) self.pointer = 0;
            self.pointer = (self.pointer << 8) | byte;
            self.pointer_bytes += 1;
            return;
        }
        switch (self.pointer) {
            reg.format => self.format = byte,
            reg.isp_mux => self.isp_mux = byte,
            reg.test_pattern => self.test_pattern = byte,
            else => {
                self.unmodelled += 1;
                return;
            },
        }
        self.writes += 1;
    }

    /// One byte per read: SCCB has no auto-increment, so a driver that wants
    /// the next register sends its pointer again.
    pub fn read(self: *Sensor, into: []u8) usize {
        if (into.len == 0) return 0;
        into[0] = switch (self.pointer) {
            reg.id_high => blk: {
                self.id_reads += 1;
                break :blk reg.id_high_value;
            },
            reg.id_low => blk: {
                self.id_reads += 1;
                break :blk reg.id_low_value;
            },
            reg.format => self.format,
            reg.isp_mux => self.isp_mux,
            reg.test_pattern => self.test_pattern,
            else => 0,
        };
        return 1;
    }

    pub fn stop(self: *Sensor) void {
        self.pointer_bytes = 0;
    }

    pub fn device(self: *Sensor) bus.Device {
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
    const self: *Sensor = @ptrCast(@alignCast(context));
    self.write(byte);
}

fn readThunk(context: *anyopaque, into: []u8) usize {
    const self: *Sensor = @ptrCast(@alignCast(context));
    return self.read(into);
}

fn stopThunk(context: *anyopaque) void {
    const self: *Sensor = @ptrCast(@alignCast(context));
    self.stop();
}
