//! The extra-MRAM option-setting cells: what a Program command is allowed to
//! target, and what it is allowed to do to a cell that was already written.
//!
//! HUM Ch 5 Figure 5.2 p 237 labels this region "Extra MRAM
//! (option-setting memory)". It is not a data flash and the RA8D2 has no
//! user EEPROM: HUM Ch 59.7.4.5 Table 59.15 p 3592 enumerates every address
//! the Program command accepts and they all lie between 0x02E0_7600 and
//! 0x02E1_79F0, holding the FSBL setting, the measurement report and code
//! certificate addresses, general-purpose OTP, PBPS, POFSPS, REVOKE, the
//! HUK-zeroize enable and the anti-rollback counter.
//!
//! One-time programmable is the part dev leaves out. Its own header says
//! so: "a real OTP cell cannot be erased and re-programmed, so an emulator
//! pass for an erase/rewrite demo is optimistic". dev programs through to
//! guest RAM, so a rewrite demo passes there every time. Here a cell only
//! ever loses bits, the way the silicon does, and a command asking for a
//! bit back is refused rather than quietly doing less than it asked.
//!
//! The store is sparse: a run programs a word or two of option memory and
//! leaves the rest alone, so only what was written is held. A cell nobody
//! has programmed reads as erased.
const std = @import("std");

/// Program targets and cells named by HUM Ch 59.7.4.5 Table 59.15.
pub const window = struct {
    pub const lo: u32 = 0x02E0_7600;
    /// Last Program start address, not the end of a contiguous data array.
    pub const hi: u32 = 0x02E1_79F0;
    pub const program_bytes: u32 = 16;
    /// What an unprogrammed cell holds.
    pub const erased: u8 = 0xFF;

    pub fn holds(address: u32, len: usize) bool {
        if (len == 0 or len > program_bytes) return false;
        if (address % program_bytes != 0) return false;
        return isTarget(address);
    }

    fn isTarget(address: u32) bool {
        return address == lo or
            inRange(address, 0x02E0_7610, 0x02E0_7690) or
            inRange(address, 0x02E0_76A0, 0x02E0_76F0) or
            inRange(address, 0x02E1_7700, 0x02E1_7770) or
            inRange(address, 0x02E1_7780, 0x02E1_77F0) or
            address == 0x02E1_7900 or
            address == 0x02E1_7910 or
            address == 0x02E1_7920 or
            address == 0x02E1_7930 or
            inRange(address, 0x02E1_7950, 0x02E1_79F0);
    }

    fn inRange(address: u32, first: u32, last: u32) bool {
        return address >= first and address <= last;
    }
};

/// The cells something has programmed, by address.
pub const Cells = struct {
    written: std.AutoHashMap(u32, u8),

    pub fn init(allocator: std.mem.Allocator) Cells {
        return .{ .written = std.AutoHashMap(u32, u8).init(allocator) };
    }

    pub fn deinit(self: *Cells) void {
        self.written.deinit();
    }

    /// Cells currently holding something other than the erased value.
    pub fn live(self: *const Cells) u32 {
        return self.written.count();
    }

    pub fn byte(self: *const Cells, address: u32) u8 {
        return self.written.get(address) orelse window.erased;
    }

    /// Whether this payload only clears bits. A one-time-programmable cell
    /// cannot be returned, so a byte asking for a bit the cell has already
    /// lost is a rewrite and the command that carries it cannot run.
    pub fn rewrites(self: *const Cells, address: u32, payload: []const u8) bool {
        for (payload, 0..) |value, index| {
            const at = address + @as(u32, @intCast(index));
            const current = self.byte(at);
            if (value & current != value) return true;
        }
        return false;
    }

    /// Program the payload. Bits only clear, so what lands is the cell and
    /// the byte ANDed together, the same rule the NOR array behind XSPI
    /// keeps.
    pub fn program(self: *Cells, address: u32, payload: []const u8) !void {
        for (payload, 0..) |value, index| {
            const at = address + @as(u32, @intCast(index));
            const next = self.byte(at) & value;
            if (next == window.erased) continue;
            try self.written.put(at, next);
        }
    }

    pub fn reset(self: *Cells) void {
        self.written.clearRetainingCapacity();
    }
};
