//! A serial channel's receive ring: the bytes a host or a device on the line
//! has driven back and the firmware has not read out of RDR yet.
//!
//! Split out of src/chip/periph/sci/sci.zig, which owns the channel, the status words
//! and the transmit gate, the same way src/chip/periph/sci/line.zig owns the
//! console line buffer.
//!
//! FIXED CAPACITY ON PURPOSE. There is no allocator below the bus in this
//! model, and a real UART drops what it cannot hold too. What makes the drop
//! worth reporting rather than swallowing is that it is an OVERRUN: a
//! character arrived with the previous one still unread, which is exactly
//! what CSR.ORER reports. So `push` says whether it lost anything and the
//! channel latches that into the flag; see src/chip/periph/sci/status.zig for the
//! bit and for what clears it.

/// How many unread bytes a channel can hold.
pub const limits = struct {
    pub const rx_queue: usize = 512;
};

/// A host-to-firmware byte ring.
pub const Ring = struct {
    bytes: [limits.rx_queue]u8 = undefined,
    head: usize = 0,
    tail: usize = 0,
    /// Bytes lost because the ring was full, kept for the run report.
    dropped: u32 = 0,

    pub fn empty(self: *const Ring) bool {
        return self.head == self.tail;
    }

    /// Queue what fits and count what does not. Returns true when anything
    /// was lost, which is the overrun the channel raises CSR.ORER for.
    pub fn push(self: *Ring, data: []const u8) bool {
        for (data, 0..) |byte, i| {
            const next = (self.tail + 1) % limits.rx_queue;
            if (next == self.head) {
                self.dropped += @intCast(data.len - i);
                return true;
            }
            self.bytes[self.tail] = byte;
            self.tail = next;
        }
        return false;
    }

    /// The oldest unread byte, left where it is (RA8EMU-949).
    pub fn first(self: *const Ring) ?u8 {
        if (self.empty()) return null;
        return self.bytes[self.head];
    }

    pub fn pop(self: *Ring) ?u8 {
        if (self.empty()) return null;
        const byte = self.bytes[self.head];
        self.head = (self.head + 1) % limits.rx_queue;
        return byte;
    }
};
