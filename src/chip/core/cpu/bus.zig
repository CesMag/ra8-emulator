//! The memory the Zig core fetches, loads and stores through.
//!
//! The core owns no memory. It reaches whatever the run hands it through this
//! one interface: the board's RAM and peripheral bus in a real run, a flat
//! array in a test.
const std = @import("std");
const memmap = @import("../memmap.zig");
const Gate = @import("data_gate.zig").Gate;
const code_lines = @import("code_lines.zig");
const Peer = @import("exclusive_peer.zig").Peer;
const bus_fault = @import("../../periph/bus_fault.zig");
const observer = @import("memory/observer.zig");
const Initiator = @import("memory/initiator.zig").Initiator;

/// SecurityViolation: a Non-secure access the data gate refused (RA8EMU-274).
pub const Error = error{ Unmapped, SecurityViolation };

/// Fixed host-backed ranges. Separate fields avoid a per-access region loop;
/// peripheral addresses and cross-range accesses continue through the vtable.
pub const DirectMemory = struct {
    touched: ?*@import("memory/touched.zig").Tracker = null,
    flash: ?[]u8 = null,
    sram: ?[]u8 = null,
    enabled: bool = false,
    /// The MPU check's armed flag. While it is set every access goes through
    /// the vtable, so the board bus can ask the MPU (RA8EMU-710).
    checking: ?*const bool = null,
    /// The trail hook the core's fast writes feed (H2); null records
    /// nothing (RA8EMU-D1).
    observer: ?*const observer.Observer = null,
    /// The initiator the core's own stores carry into the trail.
    initiator: Initiator = .none,
    /// The machine's block fanout, which a fast write invalidates.
    lines: ?*const code_lines.Fanout = null,

    /// Where an access lands: the canonical region base (the Non-secure
    /// aliases fold onto their Secure region), the offset inside it and the
    /// host bytes (RA8EMU-D1).
    const Located = struct { base: u32, offset: usize, data: []u8 };

    inline fn locate(self: *const DirectMemory, address: u32, len: usize) ?Located {
        if (self.checking) |armed| if (armed.*) return null;
        if (address >= memmap.mram_base and address < memmap.mram_end) {
            const offset = address - memmap.mram_base;
            if (len > memmap.mram_end - memmap.mram_base - offset) return null;
            const bytes = self.flash orelse return null;
            return .{ .base = memmap.mram_base, .offset = offset, .data = bytes[offset..][0..len] };
        }
        if (address >= memmap.ns_mram_base and address < memmap.ns_mram_end) {
            const offset = address - memmap.ns_mram_base;
            if (len > memmap.ns_mram_end - memmap.ns_mram_base - offset) return null;
            const bytes = self.flash orelse return null;
            return .{ .base = memmap.mram_base, .offset = offset, .data = bytes[offset..][0..len] };
        }
        if (address >= memmap.sram_base and address < memmap.sram_end) {
            const offset = address - memmap.sram_base;
            if (len > memmap.sram_end - memmap.sram_base - offset) return null;
            const bytes = self.sram orelse return null;
            return .{ .base = memmap.sram_base, .offset = offset, .data = bytes[offset..][0..len] };
        }
        if (address >= memmap.ns_sram_base and address < memmap.ns_sram_end) {
            const offset = address - memmap.ns_sram_base;
            if (len > memmap.ns_sram_end - memmap.ns_sram_base - offset) return null;
            const bytes = self.sram orelse return null;
            return .{ .base = memmap.sram_base, .offset = offset, .data = bytes[offset..][0..len] };
        }
        return null;
    }

    inline fn span(self: *const DirectMemory, address: u32, len: usize) ?[]u8 {
        const hit = self.locate(address, len) orelse return null;
        return hit.data;
    }

    inline fn read(self: *const DirectMemory, address: u32, into: []u8) bool {
        const data = self.span(address, into.len) orelse return false;
        @memcpy(into, data);
        return true;
    }

    /// A fast-path write (H2): the pre-image leaves through the trail
    /// observer before the bytes move, then the block fanout hears the
    /// range (RA8EMU-D1).
    inline fn write(self: *const DirectMemory, address: u32, bytes: []const u8) bool {
        const hit = self.locate(address, bytes.len) orelse return false;
        if (self.touched) |tracker| tracker.note(hit.base, hit.offset, bytes.len);
        if (self.observer) |o| o.bytes(.{ .base = hit.base, .offset = hit.offset, .initiator = self.initiator, .pre = hit.data, .new = bytes });
        @memcpy(hit.data, bytes);
        if (self.lines) |fan| fan.notify(address, bytes.len);
        return true;
    }
};

pub const Bus = struct {
    ctx: *anyopaque,
    vtable: *const VTable,
    direct: ?*const DirectMemory = null,
    /// Attribution on data accesses; null checks nothing (RA8EMU-274).
    gate: ?*Gate = null,
    /// Where the last access the bus behind refused went, for the BusFault's
    /// BFAR; null records nothing (RA8EMU-641).
    miss: ?*u32 = null,
    /// Counts the BusFaults those refusals raised, for the run report.
    tally: ?*bus_fault.Tally = null,
    /// The other core's exclusive monitor, cleared by a store into the word
    /// it tagged; null on a single-core run (RA8EMU-134).
    peer: ?Peer = null,
    /// The machine's block fanout, where a run's block cache joins; null on
    /// a bus with no store behind it (RA8EMU-D1).
    lines: ?*code_lines.Fanout = null,

    pub const VTable = struct {
        read: *const fn (ctx: *anyopaque, address: u32, into: []u8) Error!void,
        write: *const fn (ctx: *anyopaque, address: u32, bytes: []const u8) Error!void,
        /// Sets bits in a status word without a store; null reads and
        /// writes the word back instead.
        latch: ?*const fn (ctx: *anyopaque, address: u32, bits: u32) Error!void = null,
        /// Counts `times` more reads at `address` that would each answer as
        /// the last did and change nothing but a counter; false, having done
        /// nothing, when such a read is not repeatable. Times 0 only asks
        /// (RA8EMU-595). Null repeats nothing.
        repeat: ?*const fn (ctx: *anyopaque, address: u32, len: usize, times: u64) bool = null,
        /// Fills `into` from a peripheral register with none of a read's
        /// side effects; false when nothing can (RA8EMU-948). Null peeks
        /// nothing.
        peek: ?*const fn (ctx: *anyopaque, address: u32, into: []u8) bool = null,
    };

    /// A debugger's look at one register: true with `into` filled, or false
    /// having changed nothing, when the bus behind keeps no peek there.
    pub fn peek(self: Bus, address: u32, into: []u8) bool {
        if (self.gate) |gate| if (gate.refuses(address, into.len)) return false;
        const look = self.vtable.peek orelse return false;
        return look(self.ctx, address, into);
    }

    pub fn repeat(self: Bus, address: u32, len: usize, times: u64) bool {
        const answer = self.vtable.repeat orelse return false;
        return answer(self.ctx, address, len, times);
    }

    pub inline fn read(self: Bus, address: u32, into: []u8) Error!void {
        if (self.gate) |gate| if (gate.refuses(address, into.len)) return error.SecurityViolation;
        if (into.len != 0) if (self.direct) |memory| {
            if (memory.enabled and memory.read(address, into)) return;
        };
        return self.vtable.read(self.ctx, address, into) catch |err| self.missed(err, address);
    }

    pub inline fn write(self: Bus, address: u32, bytes: []const u8) Error!void {
        if (self.gate) |gate| if (gate.refuses(address, bytes.len)) return error.SecurityViolation;
        if (self.peer) |other| other.stored(address, bytes.len);
        if (bytes.len != 0) {
            if (self.direct) |memory| {
                if (memory.enabled and memory.write(address, bytes)) return;
            }
            if (self.lines) |fan| fan.notify(address, bytes.len);
        }
        return self.vtable.write(self.ctx, address, bytes) catch |err| self.missed(err, address);
    }

    /// Record `address` as the refused one, then hand `err` back.
    fn missed(self: Bus, err: Error, address: u32) Error {
        if (self.miss) |at| at.* = address;
        return err;
    }

    /// Set `bits` in a status word the way the core raises a fault. This is
    /// not a store: a bus with a write-one-to-clear model behind it must not
    /// take the core's own latch for an acknowledge (RA8EMU-394).
    pub fn latch(self: Bus, address: u32, bits: u32) Error!void {
        if (self.vtable.latch) |set| return set(self.ctx, address, bits);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, try self.readWord(address) | bits, .little);
        return self.write(address, &bytes);
    }

    pub fn readHalf(self: Bus, address: u32) Error!u16 {
        var bytes: [2]u8 = undefined;
        try self.read(address, &bytes);
        return std.mem.readInt(u16, &bytes, .little);
    }

    pub fn readWord(self: Bus, address: u32) Error!u32 {
        var bytes: [4]u8 = undefined;
        try self.read(address, &bytes);
        return std.mem.readInt(u32, &bytes, .little);
    }

    pub fn writeWord(self: Bus, address: u32, value: u32) Error!void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        return self.write(address, &bytes);
    }
};
