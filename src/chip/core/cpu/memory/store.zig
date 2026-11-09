//! The Zig core's host-backed memory store. Off-chip SDRAM and OSPI sit
//! behind the external port the board attaches (RA8EMU-1041).
const std = @import("std");
const memmap = @import("../../memmap.zig");
const external_port = @import("external_port.zig");
const Initiator = @import("initiator.zig").Initiator;
const extra = @import("extra.zig");
const observer = @import("observer.zig");
const code_lines = @import("../code_lines.zig");

pub const Error = error{OutOfMemory};
pub const AccessError = error{Unmapped} || Error;
pub const MapError = extra.Error;

/// Where a byte write lands: the canonical backing region's base, the
/// offset inside it, and the mutable host bytes (RA8EMU-D1). Aliases fold
/// onto the region they view, so every write into one storage reports one
/// identity.
pub const Located = struct { base: u32, offset: usize, bytes: []u8 };

pub const Store = struct {
    touched: @import("touched.zig").Tracker = .{},
    pages: [memmap.ram.len]?[]u8 = @splat(null),
    owned: [memmap.ram.len]bool = @splat(false),
    extra: extra.Extra = .{},
    port: ?external_port.Port = null,
    owns_port: bool = false,
    /// The trail hook this store feeds (H1); null records nothing.
    observer: ?*const observer.Observer = null,
    /// This machine's block fanout, which its writes invalidate.
    fanout: code_lines.Fanout = .{},
    /// The store shared regions were borrowed from, when this is a second
    /// core's store: its fanout and trail are the machine's.
    lender: ?*Store = null,

    /// Back every fixed region. A second core borrows shared SRAM/SDRAM and
    /// the same external port, while retaining private MRAM, TCM and PPB.
    pub fn init(lender: ?*Store) Error!Store {
        var self: Store = .{};
        errdefer self.deinit();
        for (memmap.ram, 0..) |entry, index| {
            if (viewOf(entry.base) != null) continue;
            if (lender) |first| if (shared(entry.base)) {
                self.pages[index] = first.pages[index];
                continue;
            };
            self.pages[index] = try allocate(entry.size);
            self.owned[index] = true;
        }
        for (memmap.ram, 0..) |entry, index| {
            const secure = viewOf(entry.base) orelse continue;
            self.pages[index] = self.pages[indexOf(secure).?];
        }
        if (lender) |first| self.port = first.port;
        self.lender = lender;
        return self;
    }

    /// Put the board's off-chip memory behind the SDRAM and OSPI apertures.
    /// The board owns the backing and frees it after this store is gone.
    pub fn attachExternal(self: *Store, port: external_port.Port) void {
        const secure_index = indexOf(memmap.sdram_base).?;
        if (self.owned[secure_index]) if (self.pages[secure_index]) |old| std.heap.page_allocator.free(old);
        self.pages[secure_index] = port.sdram;
        self.owned[secure_index] = false;
        self.pages[indexOf(memmap.ns_sdram_base).?] = port.sdram;
        self.port = port;
        self.owns_port = true;
        self.barrier(.attach_external);
    }

    pub fn deinit(self: *Store) void {
        if (self.owns_port) {
            self.pages[indexOf(memmap.sdram_base).?] = null;
            self.pages[indexOf(memmap.ns_sdram_base).?] = null;
        }
        for (&self.pages, &self.owned) |*held, *mine| {
            if (mine.*) if (held.*) |bytes| std.heap.page_allocator.free(bytes);
            held.* = null;
            mine.* = false;
        }
        self.extra.deinit();
        self.port = null;
        self.owns_port = false;
        self.observer = null;
        self.lender = null;
    }

    /// Zero every region this store owns and drop the windows it mapped,
    /// so a live store reads as a fresh one before a snapshot fills it
    /// (RA8EMU-768). Borrowed regions are the lender's to clear.
    pub fn wipe(self: *Store) void {
        self.touched = .{};
        self.barrier(.wipe);
        for (self.pages, self.owned) |held, mine| {
            if (mine) if (held) |bytes| @memset(bytes, 0);
        }
        if (self.owns_port) @memset(self.port.?.sdram, 0);
        self.extra.deinit();
        self.notifyCodeRanges();
    }

    pub fn touches(self: *const Store) *@import("touched.zig").Tracker {
        if (self.lender) |first| return first.touches();
        return @constCast(&self.touched);
    }

    pub fn region(self: *const Store, base: u32) ?[]const u8 {
        return self.pages[indexOf(base) orelse return null];
    }

    /// A directly addressable host span. Mapped OSPI stays behind read/write
    /// so its erased inversion and NOR program semantics cannot be bypassed.
    pub fn span(self: *const Store, address: u32, len: usize) ?[]const u8 {
        const hit = self.locate(address, len) orelse return null;
        return hit.bytes;
    }

    /// Resolve an access to the storage it mutates, with the canonical
    /// region base the trail records (RA8EMU-D1). OSPI stays out: its
    /// erased inversion and NOR program semantics cannot be bypassed.
    pub fn locate(self: *const Store, address: u32, len: usize) ?Located {
        if (self.port) |*port| {
            if (port.geometry.locate(address, len)) |hit| {
                if (hit.kind == .sdram) return .{ .base = memmap.sdram_base, .offset = hit.offset, .bytes = port.sdram[hit.offset..][0..len] };
                return null;
            }
            if (port.geometry.overlaps(address, len)) return null;
        }
        for (memmap.ram, 0..) |entry, index| {
            if (address < entry.base or address >= entry.end()) continue;
            const offset = address - entry.base;
            const bytes = self.pages[index] orelse return null;
            if (offset > bytes.len or len > bytes.len - offset) return null;
            const base = viewOf(entry.base) orelse entry.base;
            return .{ .base = base, .offset = offset, .bytes = bytes[offset..][0..len] };
        }
        const hit = self.extra.locate(address, len) orelse return null;
        return .{ .base = hit.base, .offset = hit.offset, .bytes = hit.bytes };
    }

    pub fn read(self: *Store, initiator: Initiator, address: u32, into: []u8) AccessError!void {
        if (into.len == 0) return;
        if (self.port) |*port| if (port.geometry.locate(address, into.len)) |hit| {
            switch (hit.kind) {
                .ospi => if (!port.flash.read(hit.offset, into)) return AccessError.Unmapped,
                .sdram => @memcpy(into, port.sdram[hit.offset..][0..into.len]),
            }
            port.meter.note(initiator, hit, .read, into.len);
            return;
        };
        @memcpy(into, self.span(address, into.len) orelse return AccessError.Unmapped);
    }

    /// A byte write (H1): the pre-image leaves through the trail observer
    /// before the bytes move, with the initiator that made the write.
    /// OSPI writes take the Flash model's own hooks (H3) and record nothing
    /// here; a NOR write is not a byte overwrite.
    pub fn write(self: *Store, initiator: Initiator, address: u32, bytes: []const u8) AccessError!void {
        if (bytes.len == 0) return;
        if (self.port) |*port| if (port.geometry.locate(address, bytes.len)) |hit| {
            switch (hit.kind) {
                .ospi => if (!(try port.flash.write(hit.offset, bytes))) return AccessError.Unmapped,
                .sdram => {
                    self.hookBytes(initiator, memmap.sdram_base, hit.offset, port.sdram[hit.offset..][0..bytes.len], bytes);
                    @memcpy(port.sdram[hit.offset..][0..bytes.len], bytes);
                },
            }
            port.meter.note(initiator, hit, .write, bytes.len);
            return;
        };
        const target = self.locate(address, bytes.len) orelse return AccessError.Unmapped;
        self.hookBytes(initiator, target.base, target.offset, target.bytes, bytes);
        @memcpy(target.bytes, bytes);
    }

    /// The undo trail's raw restore: `bytes` land at `address` past the
    /// gates, the MPU, write-one-to-clear and NOR program semantics,
    /// matching what the trail recorded (RA8EMU-D1). The restore records
    /// nothing itself, but code the restored bytes reach must re-execute,
    /// so the block fanout hears the range. OSPI-backed bytes land through
    /// the Flash model's own raw path (H6): past NOR semantics, recording
    /// nothing, the sectors the shadow restores re-executing as usual.
    pub fn rawWrite(self: *Store, address: u32, bytes: []const u8) AccessError!void {
        if (bytes.len == 0) return;
        self.touches().invalidate();
        if (self.port) |*port| if (port.geometry.locate(address, bytes.len)) |hit| {
            switch (hit.kind) {
                .ospi => port.flash.rawWrite(hit.offset, bytes),
                .sdram => @memcpy(port.sdram[hit.offset..][0..bytes.len], bytes),
            }
            return;
        };
        const target = self.locate(address, bytes.len) orelse return AccessError.Unmapped;
        @memcpy(target.bytes, bytes);
        self.notifyCodeRanges();
    }

    /// A structural change around byte writes (H5): the trail stamps one
    /// barrier entry, and ranges this store zeroes drop formed blocks so
    /// restored code executes fresh.
    pub fn barrier(self: *Store, event: observer.Barrier) void {
        if (event == .snapshot_load) self.touches().invalidate();
        if (self.trail()) |o| o.barrier(event);
    }

    pub fn backed(self: *const Store, address: u32, len: usize) bool {
        if (self.port) |*port| if (port.geometry.locate(address, len) != null) return true;
        return self.span(address, len) != null;
    }

    pub fn map(self: *Store, base: u32, size: u32) MapError!void {
        if (self.span(base, 1) != null) return MapError.Mapped;
        if (external_port.supportedOverlap(base, size)) return MapError.Mapped;
        try self.extra.map(base, size);
        self.barrier(.{ .mapped = .{ .base = base, .size = size } });
    }

    /// The fanout this store's writes invalidate. A borrower shares the
    /// lender's, so a write through either core's store drops both cores'
    /// blocks (RA8EMU-D1).
    pub fn fan(self: *const Store) *const code_lines.Fanout {
        if (self.lender) |first| return first.fan();
        return &self.fanout;
    }

    /// The fanout a run attaches its block cache to, through the lender
    /// when this store borrows shared regions.
    pub fn fanMut(self: *Store) *code_lines.Fanout {
        if (self.lender) |first| return first.fanMut();
        return &self.fanout;
    }

    /// The trail this store feeds. A borrower feeds the lender's, so one
    /// machine records one trail however many cores write.
    pub fn trail(self: *const Store) ?*const observer.Observer {
        if (self.lender) |first| return first.trail();
        return self.observer;
    }

    /// Tell the block fanout about every tracked code range this store
    /// owns, after those bytes changed outside a write path.
    pub fn notifyCodeRanges(self: *const Store) void {
        for (memmap.ram, self.owned) |entry, mine| {
            if (!mine) continue;
            if (entry.base != memmap.dtcm_base and entry.base != memmap.mram_base and entry.base != memmap.sram_base) continue;
            self.fan().notify(entry.base, @intCast(entry.end() - entry.base));
        }
    }

    /// The mutable host bytes of one fixed region, for the core's
    /// fast-path backing and a snapshot's apply; hook sites only (RA8EMU-D1).
    pub fn mutRegion(self: *Store, base: u32) ?[]u8 {
        return self.pages[indexOf(base) orelse return null];
    }

    inline fn hookBytes(self: *const Store, initiator: Initiator, base: u32, offset: usize, pre: []const u8, new: []const u8) void {
        self.touches().note(base, offset, new.len);
        if (self.trail()) |o| o.bytes(.{ .base = base, .offset = offset, .initiator = initiator, .pre = pre, .new = new });
    }
};

fn viewOf(base: u32) ?u32 {
    if (base == memmap.ns_mram_base) return memmap.mram_base;
    for (memmap.alias_of) |pair| if (pair.view == base) return pair.of;
    return null;
}

fn shared(base: u32) bool {
    for (memmap.alias_of) |pair| if (pair.of == base) return true;
    return false;
}

fn indexOf(base: u32) ?usize {
    for (memmap.ram, 0..) |entry, index| if (entry.base == base) return index;
    return null;
}

fn allocate(size: u32) Error![]u8 {
    const bytes = std.heap.page_allocator.alloc(u8, size) catch return Error.OutOfMemory;
    @memset(bytes, 0);
    return bytes;
}
