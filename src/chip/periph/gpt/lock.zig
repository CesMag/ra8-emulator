//! GTWP: the key a channel's registers stay shut behind.
//!
//! GTWP is the first word of every GPT channel window (+0x00,
//! `R_GPT0.GTWP` in ra8_gpt_regs.h line 56, "Write-Protection"). Bit 0 is
//! WP, the protection itself, and the upper byte is a password: a store only
//! reaches WP when it carries 0xA5 there. That is ra8_gpt.c's `ra8_gtwp_t`
//! (line 55): `k_ra8_gtwp_key_unlock` 0xA500, "password in upper byte,
//! WP=0", and `k_ra8_gtwp_key_lock` 0xA501, the same password with WP=1,
//! citing HUM Ch 22.2.1 "GTWP : General PWM Timer Write Protection Register"
//! p 883..884.
//!
//! The register was shadow storage here, so protection neither locked nor
//! rejected anything and every store landed whatever GTWP held. The HAL is
//! built the other way round: every entry point that touches a channel
//! brackets its work with the two keys. `ra8_gpt_start` (line 291) unlocks,
//! writes GTSTP, GTCR, GTPR, GTCNT and GTSTR, then locks; `ra8_gpt_stop`,
//! `ra8_gpt_period_set`, `ra8_gpt_duty_cycle_set`, `ra8_gpt_capture_source`
//! (line 538), the three-phase pair and the rest do the same, twenty-two
//! bracketed windows in one file. So a channel the HAL has finished with is
//! LOCKED, and a later store that skips the key is one the part drops on the
//! floor. Against the old model such a store took effect, which is the
//! optimistic direction: a driver bug that forgets to unlock ran here and
//! failed on the bench.
//!
//! WHAT THE PROTECTION COVERS HERE lives in src/chip/periph/gpt/window.zig as
//! `protected`: the counter and period, the control word, the start / stop /
//! clear requests, the compares and their buffers, and GTBER. GTWP itself is
//! never protected, or nothing could ever unlock it.
//!
//! GTST IS NOT IN THAT SET, and used to be. The protected set was taken to
//! be every register this model interprets, and GTST is the one register
//! ra8_gpt.c writes with no bracket around it, at both of its sites:
//! `ra8_gpt_clear_status` and the ISR path that acknowledges the flag it was
//! entered for. Because `ra8_gpt_start_free_run` locks the channel on its
//! way out, every acknowledgement a polling or interrupt-driven driver makes
//! arrives with GTWP shut, and this model dropped all of them. The flag
//! stood, so a driver waiting for its own clear to take spun on a bit it had
//! just cleared. window.zig's header carries the full evidence.
//!
//! NOT MODELLED, AND NOT GUESSED: HUM's own list of protected registers.
//! Neither tree carries the table (ra8_gpt_regs.h gives GTWP an offset and
//! no field map, and the key enum is the whole of it), so the shadowed
//! registers this model does not interpret keep taking stores while a
//! channel is locked rather than being swept into a set nobody here has
//! read. And what GTWP reads back: the key is a password, not state, so a
//! read answers the WP bit alone. No driver in either tree ever reads the
//! register, so nothing observes the difference.
const std = @import("std");

/// Where the register sits in a channel (ra8_gpt_regs.h line 56).
pub const off = struct {
    pub const gtwp: u32 = 0x00;
};

/// GTWP's fields and the two keys the HAL writes (ra8_gpt.c line 55,
/// HUM Ch 22.2.1 p 883..884).
pub const field = struct {
    /// WP, bit 0: set means the channel is shut.
    pub const wp: u32 = 0x0000_0001;
    /// PRKEY, the upper byte of the low half-word.
    pub const prkey: u32 = 0x0000_FF00;
    /// The password a store must carry to reach WP.
    pub const password: u32 = 0x0000_A500;
    pub const unlock: u32 = 0x0000_A500;
    pub const lock: u32 = 0x0000_A501;
};

/// One channel's protection: the word a store is assembling, whether the
/// channel is shut, and how many stores that cost.
pub const Lock = struct {
    /// The last word stored to GTWP, byte lanes and all, so a narrow store
    /// that fills the password in one go and WP in another still reads as
    /// the word the part sees.
    staged: u32 = 0,
    shut: bool = false,
    /// Stores dropped because the channel was shut, so an image that locks
    /// and then forgets to unlock is distinguishable from one that never
    /// wrote anything.
    refused: u32 = 0,

    /// Take one store to GTWP, however wide. WP moves only when the word the
    /// access leaves behind carries the password; a store without it leaves
    /// protection as it was, which is what the password is for.
    ///
    /// The key is judged ONCE, on the whole access, never lane by lane. A
    /// word store of zero passes through 0xA500 after its first byte lands,
    /// and a lane-by-lane reading takes that for the unlock key and opens a
    /// channel the store was never addressed to open.
    pub fn store(self: *Lock, index: u32, width: u3, word: u32) void {
        var lane: u32 = 0;
        while (lane < width and index + lane < 4) : (lane += 1) {
            const shift: u5 = @intCast((index + lane) * 8);
            const mask = ~(@as(u32, 0xFF) << shift);
            const byte = (word >> @intCast(lane * 8)) & 0xFF;
            self.staged = (self.staged & mask) | (byte << shift);
        }
        if (self.staged & field.prkey != field.password) return;
        self.shut = self.staged & field.wp != 0;
    }

    /// What a read of GTWP answers: the WP bit, never the password.
    pub fn value(self: *const Lock) u32 {
        return if (self.shut) field.wp else 0;
    }

    /// May a store to this channel-local offset land?
    pub fn admits(self: *Lock, local: u32, protected: bool) bool {
        if (!self.shut or !protected or local < off.gtwp + 4) return true;
        self.refused +%= 1;
        return false;
    }

    pub fn quiet(self: *const Lock) bool {
        return !self.shut and self.refused == 0 and self.staged == 0;
    }
};
