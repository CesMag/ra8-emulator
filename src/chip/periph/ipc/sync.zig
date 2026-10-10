//! IPCSEMn and the NMI windows: the half of the IPC block below the channels.
//!
//! Everything under offset 0xC0 in the IPC window is the cross-core handshake
//! that is not a message: sixteen hardware semaphores and, per unit, a
//! one-bit NMI doorbell. The channel FIFOs above carry the payload; these
//! carry the right to touch what the payload points at.
//!
//!   IPCSEM0..15   +0x000 .. +0x03C, 4 bytes apart, LOCK at bit 0
//!   IPC0NMI       +0x080  STA, +0x084 SET, +0x088 CLR   (CPU1 -> CPU0)
//!   IPC1NMI       +0x090  STA, +0x094 SET, +0x098 CLR   (CPU0 -> CPU1)
//!
//! A SEMAPHORE IS TAKEN BY READING IT. HUM Ch 3.2.3 p 210: the set condition
//! for LOCK is the read itself, and the read hands back the value from
//! BEFORE the set. So a claimant that reads 0 has just won the lock, and one
//! that reads 1 found it already held by somebody else. Release is the
//! opposite direction and the usual one: write a 1 to LOCK to clear it.
//! ra8_ipc_sem_try_take in the firmware is exactly that pair, and
//! ra8_ipc_sem_is_locked has to release after a diagnostic read precisely
//! because the read took the lock as a side effect.
//!
//! That side effect is the whole reason this file exists. Before it, the
//! region was a plain shadow: a read answered the last word written, so a
//! core that claimed a semaphore read back 0 and believed it won, and the
//! second core reading the same register also read 0 and believed the same
//! thing. Two winners, no contention ever reported, and a firmware bug that
//! only shows up on silicon. dev is worse again: it answers zero to every
//! read down here and drops every write, so a driver spinning on
//! ra8_ipc_sem_take_timeout gets 0 forever and always wins.
//!
//! A READ THAT CANNOT CARRY LOCK CANNOT TAKE IT. LOCK is bit 0, so it lives
//! in the lowest byte of the word and an access that does not name that byte
//! carries none of it. The take used to fire on any read landing anywhere in
//! a semaphore's word, and the caller above then cut the answer down to the
//! lanes the access named, which above bit 0 is nothing. So a byte read at
//! IPCSEM0+1 took a lock that was free and answered 0, and 0 is precisely
//! what ra8_ipc_sem_try_take reads as "we just acquired": the probe took the
//! lock and the next honest claimant was told it had won a lock somebody
//! else was holding. TWO WINNERS, which is the exact failure this file's
//! read side effect exists to make visible rather than to manufacture. Now
//! an access that names no part of LOCK takes nothing, is counted, and reads
//! back zero, leaving the lock where it stood.
//!
//! THE WRITE SIDE ALREADY HAD THIS RIGHT, the same way sci.zig's TDR did
//! before its read side was fixed: release() tests `value & sem.lock`, so a
//! byte store of 1 at IPCSEM0+1 arrives merged as 0x0100 and releases
//! nothing. Only the read direction was missing the rule.
//!
//! NOT MODELLED, AND NOT GUESSED: IPCSAR / IPCPAR, the security and
//! privilege attribution for these registers, which live in CPSCU at
//! 0x4000_8610 and not in this window. An NMI a core raises at itself is
//! latched and counted but nothing is delivered: the NMI path into the
//! engine is a later slice, and the status bit a driver polls is the part a
//! headless run can check today.
const std = @import("std");

/// Semaphore geometry (ra8_ipc_regs.h, IPCSEM0 0x000 .. IPCSEM15 0x03C).
pub const sem = struct {
    pub const base: u32 = 0x000;
    pub const count: usize = 16;
    pub const stride: u32 = 0x4;
    pub const span: u32 = stride * count;
    /// LOCK, bit 0: set by reading, cleared by writing a one.
    pub const lock: u32 = 0x0000_0001;
};

/// NMI geometry: two unit windows, 0x10 apart, three registers each.
pub const nmi = struct {
    pub const base: u32 = 0x080;
    pub const units: usize = 2;
    pub const stride: u32 = 0x10;
    pub const span: u32 = stride * units;
    pub const off_sta: u32 = 0x00;
    pub const off_set: u32 = 0x04;
    pub const off_clr: u32 = 0x08;
    /// The single request bit each of the three registers carries.
    pub const bit: u32 = 0x0000_0001;
};

/// What a read of a semaphore told the reader, which is not what it left
/// behind: the value returned is the state before the read took the lock.
pub const Claim = enum { won, contended };

/// One semaphore: a lock bit, and enough counting to say who lost.
pub const Semaphore = struct {
    locked: bool = false,
    /// Reads that found it free and therefore took it.
    takes: u32 = 0,
    /// Reads that found it already held.
    contentions: u32 = 0,
    /// Writes of a one that dropped a lock that was standing.
    releases: u32 = 0,
    /// Writes of a one at a lock nobody held.
    stray_releases: u32 = 0,
    /// Reads that named no part of LOCK, so they took nothing.
    unnamed_reads: u32 = 0,

    pub fn quiet(self: *const Semaphore) bool {
        return !self.locked and self.takes == 0 and self.contentions == 0 and
            self.releases == 0 and self.stray_releases == 0 and
            self.unnamed_reads == 0;
    }

    /// The read: hand back the value as it stood, then set LOCK regardless.
    /// Both halves matter, and the second is the one a shadow never does.
    pub fn take(self: *Semaphore) Claim {
        const held = self.locked;
        self.locked = true;
        if (held) {
            self.contentions +%= 1;
            return .contended;
        }
        self.takes +%= 1;
        return .won;
    }

    /// Write-one-to-clear. A zero written here says nothing at all, which is
    /// why a driver clearing a lock with a plain store of zero never does.
    pub fn release(self: *Semaphore, value: u32) void {
        if (value & sem.lock == 0) return;
        if (self.locked) {
            self.releases +%= 1;
        } else {
            self.stray_releases +%= 1;
        }
        self.locked = false;
    }
};

/// One NMI doorbell: the latched request, and the traffic over it.
pub const Doorbell = struct {
    pending: bool = false,
    /// Writes of a one at NMISET.
    sends: u32 = 0,
    /// Sends that landed on a request already standing: the receiver has not
    /// acknowledged the first one, and on silicon the second is not a second
    /// NMI, it is the same bit still up.
    coalesced: u32 = 0,
    /// Writes of a one at NMICLR that dropped a standing request.
    acks: u32 = 0,

    pub fn quiet(self: *const Doorbell) bool {
        return !self.pending and self.sends == 0 and self.coalesced == 0 and
            self.acks == 0;
    }

    pub fn set(self: *Doorbell, value: u32) void {
        if (value & nmi.bit == 0) return;
        self.sends +%= 1;
        if (self.pending) self.coalesced +%= 1;
        self.pending = true;
    }

    pub fn clear(self: *Doorbell, value: u32) void {
        if (value & nmi.bit == 0) return;
        if (self.pending) self.acks +%= 1;
        self.pending = false;
    }

    pub fn status(self: *const Doorbell) u32 {
        return if (self.pending) nmi.bit else 0;
    }
};

/// Where an offset below the channel windows lands.
pub const Target = union(enum) {
    semaphore: usize,
    nmi_status: usize,
    nmi_set: usize,
    nmi_clear: usize,
};

/// Decode an IPC window offset below 0xC0. Null means the gaps: 0x040..0x07F
/// and the two unused words in each NMI unit window, which stay shadow.
pub fn decode(offset: u32) ?Target {
    if (offset < sem.span) return .{ .semaphore = offset / sem.stride };
    if (offset < nmi.base or offset >= nmi.base + nmi.span) return null;
    const relative = offset - nmi.base;
    const unit = relative / nmi.stride;
    return switch (relative % nmi.stride) {
        nmi.off_sta => .{ .nmi_status = unit },
        nmi.off_set => .{ .nmi_set = unit },
        nmi.off_clr => .{ .nmi_clear = unit },
        else => null,
    };
}

/// The semaphore file and both doorbells, as one thing the IPC block owns.
pub const Sync = struct {
    semaphores: [sem.count]Semaphore = @splat(Semaphore{}),
    doorbells: [nmi.units]Doorbell = @splat(Doorbell{}),

    pub fn quiet(self: *const Sync) bool {
        for (&self.semaphores) |*one| {
            if (!one.quiet()) return false;
        }
        for (&self.doorbells) |*one| {
            if (!one.quiet()) return false;
        }
        return true;
    }

    /// Semaphores currently held, for the end-of-run line.
    pub fn held(self: *const Sync) usize {
        var total: usize = 0;
        for (&self.semaphores) |*one| {
            if (one.locked) total += 1;
        }
        return total;
    }

    /// Reads that found a semaphore already taken, across the whole file.
    pub fn contentions(self: *const Sync) u32 {
        var total: u32 = 0;
        for (&self.semaphores) |*one| total +%= one.contentions;
        return total;
    }

    /// The read side. Returns null for an offset this file does not own, so
    /// the caller falls through to its shadow.
    ///
    /// `named` is the bits of the word the access actually reaches, which
    /// decides whether a semaphore read is a take at all: LOCK is bit 0 and
    /// an access that does not name it cannot carry it either way.
    pub fn read(self: *Sync, offset: u32, named: u32) ?u32 {
        const target = decode(offset) orelse return null;
        return switch (target) {
            .semaphore => |index| blk: {
                if (named & sem.lock == 0) {
                    self.semaphores[index].unnamed_reads +%= 1;
                    break :blk 0;
                }
                break :blk switch (self.semaphores[index].take()) {
                    .won => 0,
                    .contended => sem.lock,
                };
            },
            .nmi_status => |unit| self.doorbells[unit].status(),
            // SET and CLR are actions; a read of one finds nothing behind it.
            .nmi_set, .nmi_clear => 0,
        };
    }

    /// Whether `times` more reads like this one would each find the same
    /// semaphore held and change only its contended count; when so, they
    /// are counted. Times 0 only asks (RA8EMU-595). A free semaphore does
    /// not repeat (the read takes it), nor does NMI status, which the other
    /// core can set.
    pub fn repeat(self: *Sync, offset: u32, named: u32, times: u64) bool {
        const target = decode(offset) orelse return false;
        const index = switch (target) {
            .semaphore => |at| at,
            else => return false,
        };
        const one = &self.semaphores[index];
        if (named & sem.lock == 0 or !one.locked) return false;
        one.contentions +%= @truncate(times);
        return true;
    }

    /// The write side. Returns whether this file took the store.
    pub fn write(self: *Sync, offset: u32, value: u32) bool {
        const target = decode(offset) orelse return false;
        switch (target) {
            .semaphore => |index| self.semaphores[index].release(value),
            .nmi_set => |unit| self.doorbells[unit].set(value),
            .nmi_clear => |unit| self.doorbells[unit].clear(value),
            // NMISTA is status, and status does not take a store.
            .nmi_status => {},
        }
        return true;
    }
};

/// The address of one semaphore inside the IPC window, relative to its base.
pub fn semOffset(index: usize) u32 {
    return sem.base + @as(u32, @intCast(index)) * sem.stride;
}

/// The address of one NMI register inside the IPC window, relative to base.
pub fn nmiOffset(unit: usize, register: u32) u32 {
    return nmi.base + @as(u32, @intCast(unit)) * nmi.stride + register;
}
