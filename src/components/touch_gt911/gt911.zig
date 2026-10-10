//! The GoodIX GT911 touch controller on the carrier's I2C line, 7-bit
//! address 0x5D.
//!
//! The part is addressed with a 16-bit big-endian register pointer written
//! first, then read from wherever that pointer stands. A driver probes the
//! product id, then per frame reads the status byte and, when a contact is
//! there, the eight-byte point record, and writes a zero back to status to
//! let the part latch the next frame.
//!
//! The thing dev never checked is whether there was a contact to report. Its
//! point read filled the record from whatever coordinates were left over and
//! counted a touch, so an image that read the record without looking at the
//! status byte first was handed a tap that never happened.
const bus = @import("ra8_chip").periph.riic_bus;

/// Live host touches for this panel: src/components/touch_gt911/touch_input.zig.
pub const host = @import("touch_input.zig");

pub const address: u7 = 0x5D;

/// The registers the driver names (GT911 programming guide Rev 0.1).
pub const reg = struct {
    pub const command: u16 = 0x8040;
    pub const product: u16 = 0x8140;
    pub const status: u16 = 0x814E;
    pub const point0: u16 = 0x814F;
};

/// The four ASCII bytes a probe reads back to know the part is there.
pub const product_id = [_]u8{ '9', '1', '1', 0 };

/// The status byte: buffer-ready in bit 7, the contact count in bits 3:0.
pub const status = struct {
    pub const ready: u8 = 0x80;
    pub const one_point: u8 = 0x01;
};

/// One eight-byte point record, and where each field sits in it.
pub const record = struct {
    pub const bytes: usize = 8;
    pub const track: usize = 0;
    pub const x_lsb: usize = 1;
    pub const x_msb: usize = 2;
    pub const y_lsb: usize = 3;
    pub const y_msb: usize = 4;
    pub const size_lsb: usize = 5;
    /// The size byte a contact reports. This model's own value: the part
    /// reports the touch area and nothing in this tree varies it.
    pub const pressure: u8 = 0x20;
};

/// The pointer is written high byte first.
pub const pointer_bytes: usize = 2;

/// Contacts a run may queue up front. Eight is what dev carried, and more
/// than any calibration flow in this tree asks for.
pub const queue_depth: usize = 8;

pub const Error = error{QueueFull};

pub const Contact = struct {
    x: u16 = 0,
    y: u16 = 0,
};

pub const Panel = struct {
    pointer: u16 = 0,
    /// Pointer bytes captured so far in this transfer.
    taken: usize = 0,
    /// The contact waiting to be read, if there is one.
    armed: ?Contact = null,
    queued: [queue_depth]Contact = @splat(Contact{}),
    queued_len: usize = 0,
    queued_pos: usize = 0,
    /// Contacts the firmware actually drained.
    reported: u32 = 0,
    /// Frames the firmware acknowledged by writing a zero to status.
    acked: u32 = 0,
    /// Point reads with no contact armed. dev served the last contact's
    /// coordinates again and counted a second touch.
    phantom: u32 = 0,
    /// Reads at a register this model does not carry.
    unknown: u32 = 0,

    pub fn quiet(self: *const Panel) bool {
        return self.reported == 0 and self.acked == 0 and self.phantom == 0 and
            self.unknown == 0;
    }

    /// Arm a contact directly, the way a single tap arrives.
    pub fn press(self: *Panel, contact: Contact) void {
        self.armed = contact;
    }

    /// Queue a contact for a later frame. The head is armed on the next
    /// status read, so a multi-tap flow drains one per frame.
    /// Once every queued contact has been drained the queue starts over, so
    /// a live source can keep feeding it for the whole run.
    pub fn queue(self: *Panel, contact: Contact) Error!void {
        if (self.queued_pos == self.queued_len) {
            self.queued_pos = 0;
            self.queued_len = 0;
        }
        if (self.queued_len >= queue_depth) return Error.QueueFull;
        self.queued[self.queued_len] = contact;
        self.queued_len += 1;
    }

    fn armNext(self: *Panel) void {
        if (self.armed != null) return;
        if (self.queued_pos >= self.queued_len) return;
        self.armed = self.queued[self.queued_pos];
        self.queued_pos += 1;
    }

    /// Pointer bytes first, high byte then low, then payload.
    pub fn write(self: *Panel, byte: u8) void {
        if (self.taken < pointer_bytes) {
            self.pointer = (self.pointer << 8) | byte;
            self.taken += 1;
            return;
        }
        if (self.pointer == reg.status and byte == 0) {
            self.armed = null;
            self.acked += 1;
        }
    }

    pub fn read(self: *Panel, into: []u8) usize {
        return switch (self.pointer) {
            reg.product => readId(into),
            reg.status => self.readStatus(into),
            reg.point0 => self.readPoint(into),
            else => blk: {
                self.unknown += 1;
                break :blk 0;
            },
        };
    }

    fn readStatus(self: *Panel, into: []u8) usize {
        self.armNext();
        if (into.len == 0) return 0;
        into[0] = if (self.armed != null) status.ready | status.one_point else 0;
        return 1;
    }

    fn readPoint(self: *Panel, into: []u8) usize {
        if (into.len < record.bytes) return 0;
        const contact = self.armed orelse {
            self.phantom += 1;
            return 0;
        };
        @memset(into[0..record.bytes], 0);
        into[record.track] = 0;
        into[record.x_lsb] = @truncate(contact.x);
        into[record.x_msb] = @truncate(contact.x >> 8);
        into[record.y_lsb] = @truncate(contact.y);
        into[record.y_msb] = @truncate(contact.y >> 8);
        into[record.size_lsb] = record.pressure;
        self.armed = null;
        self.reported += 1;
        return record.bytes;
    }

    /// A transfer ended, so the next one names its own register.
    pub fn stop(self: *Panel) void {
        self.taken = 0;
    }

    pub fn device(self: *Panel) bus.Device {
        return .{
            .address = address,
            .context = self,
            .writeFn = writeThunk,
            .readFn = readThunk,
            .stopFn = stopThunk,
        };
    }
};

fn readId(into: []u8) usize {
    const served = @min(into.len, product_id.len);
    for (into[0..served], product_id[0..served]) |*slot, byte| slot.* = byte;
    return served;
}

fn writeThunk(context: *anyopaque, byte: u8) void {
    const self: *Panel = @ptrCast(@alignCast(context));
    self.write(byte);
}

fn readThunk(context: *anyopaque, into: []u8) usize {
    const self: *Panel = @ptrCast(@alignCast(context));
    return self.read(into);
}

fn stopThunk(context: *anyopaque) void {
    const self: *Panel = @ptrCast(@alignCast(context));
    self.stop();
}
