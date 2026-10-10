//! The ST LSM6DSO 6-DoF IMU on the carrier's I2C line, 7-bit address 0x6B
//! (the 6DOF IMU 12 Click ties SA0 high).
//!
//! The part is a register file behind an eight-bit pointer: a transfer names
//! its start register in the first write byte, then config bytes land or a
//! burst read serves from there, the pointer auto-incrementing either way. A
//! driver probes WHO_AM_I, sets an output data rate, then reads the gyro and
//! accelerometer blocks.
//!
//! What dev never checked is whether the part had been started. Its output
//! registers were seeded at reset and served from power-down, so an image
//! that never wrote CTRL1_XL or CTRL2_G read steady motion in the emulator
//! and nothing at all on the bench. It also carried a flat 256-byte file
//! that took a write anywhere, so a driver could store over WHO_AM_I and
//! have the part identify as whatever it had just written.
const bus = @import("ra8_chip").periph.riic.bus;

pub const address: u7 = 0x6B;

/// The registers a driver names, and the end of the map (DS12140 Rev 4,
/// register map Table 21: the part's own space stops at 0x7F).
pub const reg = struct {
    pub const who_am_i: u8 = 0x0F;
    pub const ctrl1_xl: u8 = 0x10;
    pub const ctrl2_g: u8 = 0x11;
    pub const status: u8 = 0x1E;
    pub const outx_l_g: u8 = 0x22;
    pub const outz_l_a: u8 = 0x2C;
    pub const count: usize = 0x80;
};

/// What a probe reads back to know the part is there.
pub const identity: u8 = 0x6C;

/// The two output blocks, and which control register starts each. An output
/// data rate of zero is power-down, so the high nibble deciding it is the
/// whole of "has this been started".
pub const output = struct {
    pub const gyro_first: u8 = 0x22;
    pub const gyro_last: u8 = 0x27;
    pub const accel_first: u8 = 0x28;
    pub const accel_last: u8 = 0x2D;
    pub const odr_shift: u3 = 4;
};

/// STATUS_REG's data-ready bits.
pub const ready = struct {
    pub const accel: u8 = 0x01;
    pub const gyro: u8 = 0x02;
};

/// The synthetic samples the register file comes up holding, dev's own
/// values: about +1 g on accelerometer Z at +-2 g full scale, and a small
/// steady rate on gyroscope X.
pub const seed = struct {
    pub const accel_z: u16 = 0x4000;
    pub const gyro_x: u16 = 0x0100;
};

pub const Imu = struct {
    registers: [reg.count]u8 = blk: {
        var reset = @as([reg.count]u8, @splat(0));
        reset[reg.who_am_i] = identity;
        reset[reg.outz_l_a] = @truncate(seed.accel_z);
        reset[reg.outz_l_a + 1] = @truncate(seed.accel_z >> 8);
        reset[reg.outx_l_g] = @truncate(seed.gyro_x);
        reset[reg.outx_l_g + 1] = @truncate(seed.gyro_x >> 8);
        break :blk reset;
    },
    /// Where the pointer stands, and whether this transfer has named it.
    pointer: u8 = 0,
    pointed: bool = false,
    /// Bursts the controller drained, and config bytes that landed.
    reads: u32 = 0,
    writes: u32 = 0,
    /// Stores into a register the part owns: WHO_AM_I, STATUS_REG and the
    /// output blocks. dev let every one of them land.
    read_only: u32 = 0,
    /// A pointer byte naming a register past the end of the map.
    bad_pointer: u32 = 0,
    /// Bytes asked for past the end of the map. dev widened the pointer to
    /// sixteen bits over a 256-byte file and served zeros out there.
    past_end: u32 = 0,
    /// Output reads taken with that half of the part still in power-down.
    unstarted: u32 = 0,

    pub fn quiet(self: *const Imu) bool {
        return self.reads == 0 and self.writes == 0 and self.read_only == 0 and
            self.bad_pointer == 0 and self.past_end == 0 and self.unstarted == 0;
    }

    pub fn accelRunning(self: *const Imu) bool {
        return self.registers[reg.ctrl1_xl] >> output.odr_shift != 0;
    }

    pub fn gyroRunning(self: *const Imu) bool {
        return self.registers[reg.ctrl2_g] >> output.odr_shift != 0;
    }

    /// The pointer first, then payload. A pointer past the map is refused
    /// outright, so the bytes behind it land nowhere either.
    pub fn write(self: *Imu, byte: u8) void {
        if (!self.pointed) {
            if (byte >= reg.count) {
                self.bad_pointer += 1;
                return;
            }
            self.pointer = byte;
            self.pointed = true;
            return;
        }
        self.land(byte);
    }

    fn land(self: *Imu, byte: u8) void {
        if (owned(self.pointer)) {
            self.read_only += 1;
        } else {
            self.registers[self.pointer] = byte;
            self.writes += 1;
        }
        if (@as(usize, self.pointer) + 1 >= reg.count) {
            self.past_end += 1;
            return;
        }
        self.pointer += 1;
    }

    /// Serve from the pointer on. A block whose half of the part was never
    /// started answers nothing at all, and a burst that reaches the end of
    /// the map stops there rather than running on into zeros.
    pub fn read(self: *Imu, into: []u8) usize {
        if (self.gated()) return 0;
        var served: usize = 0;
        while (served < into.len) : (served += 1) {
            const at = @as(usize, self.pointer) + served;
            if (at >= reg.count) {
                self.past_end += 1;
                break;
            }
            into[served] = self.value(@intCast(at));
        }
        if (served == 0) return 0;
        self.pointer = @intCast(@min(@as(usize, self.pointer) + served, reg.count - 1));
        self.reads += 1;
        return served;
    }

    fn value(self: *const Imu, at: u8) u8 {
        if (at == reg.status) return self.statusByte();
        return self.registers[at];
    }

    fn statusByte(self: *const Imu) u8 {
        var bits: u8 = 0;
        if (self.accelRunning()) bits |= ready.accel;
        if (self.gyroRunning()) bits |= ready.gyro;
        return bits;
    }

    fn gated(self: *Imu) bool {
        const at = self.pointer;
        if (at >= output.gyro_first and at <= output.gyro_last and !self.gyroRunning()) {
            self.unstarted += 1;
            return true;
        }
        if (at >= output.accel_first and at <= output.accel_last and !self.accelRunning()) {
            self.unstarted += 1;
            return true;
        }
        return false;
    }

    /// The transfer ended, so the next one names its own register.
    pub fn stop(self: *Imu) void {
        self.pointed = false;
    }

    pub fn device(self: *Imu) bus.Device {
        return .{
            .address = address,
            .context = self,
            .writeFn = writeThunk,
            .readFn = readThunk,
            .stopFn = stopThunk,
        };
    }
};

/// Registers the part writes and the host only reads.
fn owned(at: u8) bool {
    if (at == reg.who_am_i or at == reg.status) return true;
    return at >= output.gyro_first and at <= output.accel_last;
}

fn writeThunk(context: *anyopaque, byte: u8) void {
    const self: *Imu = @ptrCast(@alignCast(context));
    self.write(byte);
}

fn readThunk(context: *anyopaque, into: []u8) usize {
    const self: *Imu = @ptrCast(@alignCast(context));
    return self.read(into);
}

fn stopThunk(context: *anyopaque) void {
    const self: *Imu = @ptrCast(@alignCast(context));
    self.stop();
}
