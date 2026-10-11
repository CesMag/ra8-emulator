//! Which word of the PPB an SCS access from the Zig core lands on, by the
//! Security state of the core making it (RA8EMU-272).
//!
//! The rules are src/chip/periph/scs_alias.zig (which bank the access names) and
//! src/chip/periph/scb/bank.zig (where that bank's copy lives). Secure code on
//! the normal window reaches the Secure copy and on the alias window the
//! Non-secure one; Non-secure code on the normal window reaches the
//! Non-secure copy, and on the alias window reads zero and writes nothing.
//!
//! A register banked bit by bit, or one the bank table does not list yet,
//! keeps the address it was given. `Split` (RA8EMU-365, RA8EMU-415) says
//! where its two halves live: the normal word holds the shared bits and the
//! Secure copy of the banked ones, and the Non-secure copy of the banked
//! bits sits at the same word + scs_alias.offset, where wholly banked words
//! already keep theirs. `wired` (RA8EMU-419) hands the bus the split for
//! the registers wired so far.

const alias = @import("../../periph/scs_alias.zig");
const scb_bank = @import("../../periph/scb/bank.zig");
const banked = @import("../banked.zig");
const systick_bank = @import("../systick_bank.zig");

pub const Landing = union(enum) {
    /// The access goes to this address.
    at: u32,
    /// Non-secure code on the alias window: reads zero, writes are dropped.
    res0,
};

/// Where an access to `address` lands. A core with no state given is taken
/// as Secure, which is how every core runs until it changes state.
pub fn land(state: ?*const banked.Banked, address: u32) Landing {
    const secure = if (state) |s| s.current == .secure else true;
    return switch (alias.route(address, secure)) {
        .outside => .{ .at = address },
        .res0 => .res0,
        .register => |target| .{ .at = copy(target, address) },
    };
}

fn copy(target: alias.Target, address: u32) u32 {
    // Each core has a Non-secure SysTick of its own at the alias (RA8EMU-154).
    if (target.view == .non_secure and systick_bank.window.normal.covers(target.address)) {
        return target.address + alias.offset;
    }
    const word = target.address & ~@as(u32, 3);
    const within = target.address - word;
    return switch (scb_bank.backing(.{ .address = word, .view = target.view })) {
        .word => |at| at + within,
        .bit_by_bit, .unknown => address,
    };
}

/// The two words a bit-by-bit SCB register is spread over, and which copy of
/// its banked bits an access names.
pub const Split = struct {
    /// Shared bits plus the Secure copy of the banked bits (0xE000_EDxx).
    shared: u32,
    /// The Non-secure copy of the banked bits (0xE002_EDxx).
    non_secure: u32,
    /// The banked bits, as src/chip/periph/scb/bank.zig bankedBits gives them.
    mask: u32,
    view: alias.View,
    /// Write-one-to-clear (CFSR): a write names the bits to clear.
    clears: bool = false,

    /// What a word read returns, given what the two words hold.
    pub fn read(self: Split, shared_word: u32, ns_word: u32) u32 {
        const banked_word = if (self.view == .non_secure) ns_word else shared_word;
        return (shared_word & ~self.mask) | (banked_word & self.mask);
    }

    /// What each word holds after a word write of `value`.
    pub const Words = struct { shared: u32, non_secure: u32 };

    /// For a write-one-to-clear split, `shared` is the value to store
    /// through the clear model (its banked bits zero, so the Secure copy
    /// stays) and `non_secure` is the copy with the written bits cleared.
    pub fn write(self: Split, shared_word: u32, ns_word: u32, value: u32) Words {
        if (self.clears and self.view == .non_secure) {
            return .{ .shared = value & ~self.mask, .non_secure = ns_word & ~(value & self.mask) };
        }
        return switch (self.view) {
            .secure => .{ .shared = value, .non_secure = ns_word },
            .non_secure => .{
                .shared = (shared_word & self.mask) | (value & ~self.mask),
                .non_secure = (ns_word & ~self.mask) | (value & self.mask),
            },
        };
    }
};

/// The split for an access `target` names, or null when the register is not
/// banked bit by bit or its field split has not been read yet.
pub fn split(target: alias.Target, systicks: scb_bank.SysTicks) ?Split {
    const word = target.address & ~@as(u32, 3);
    return switch (scb_bank.backing(.{ .address = word, .view = target.view })) {
        .bit_by_bit => .{
            .shared = word,
            .non_secure = word + alias.offset,
            .mask = scb_bank.bankedBits(word, systicks) orelse return null,
            .view = target.view,
        },
        .word, .unknown => null,
    };
}

/// AIRCR, SCR, CCR and SHPR1 (RA8EMU-419), ICSR and SHPR3 (RA8EMU-439), then
/// SHCSR (RA8EMU-441), then CFSR (RA8EMU-444): the bit-by-bit registers
/// wired through the split.
const wired_words = [_]u32{ 0xE000_ED0C, 0xE000_ED10, 0xE000_ED14, 0xE000_ED18, icsr, shpr3, shcsr, cfsr };

const icsr: u32 = 0xE000_ED04;
const shpr3: u32 = 0xE000_ED20;
const shcsr: u32 = 0xE000_ED24;
const cfsr: u32 = 0xE000_ED28;

/// Both RA8 cores implement a SysTick per Security state, and the Zig core
/// runs both (RA8EMU-154), so ICSR, SHPR3 and SHCSR bank SysTick's bits too.
const two_systicks: scb_bank.SysTicks = .two;

/// The split an access by a core in `state` to `address` goes through, or
/// null when it takes the plain path: Secure code on the normal window, a
/// register not wired yet, or anything outside the SCB.
pub fn wired(state: ?*const banked.Banked, address: u32) ?Split {
    const secure = if (state) |s| s.current == .secure else true;
    const target = switch (alias.route(address, secure)) {
        .register => |t| t,
        .outside, .res0 => return null,
    };
    if (target.view == .secure) return null;
    const word = target.address & ~@as(u32, 3);
    for (wired_words) |candidate| {
        if (candidate != word) continue;
        var halves = split(target, two_systicks) orelse return null;
        halves.clears = word == cfsr;
        return halves;
    }
    return null;
}
