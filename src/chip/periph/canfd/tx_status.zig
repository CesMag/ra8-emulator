//! CFDTMSTSj, the transmit mailbox's result byte, and the rule that makes
//! it matter: TMTR is only honoured while TMTRF reads 00b.
//!
//! The controller writes TMTRF when a request finishes; software clears it
//! and can never set it. Leaving it standing is not cosmetic. HUM Ch 41
//! "CFDTMSTSj.TMTRF" p ~2756 says a transmit request is only taken when
//! TMTRF is 00b, so once a frame has gone and left TMTRF = 10b, every
//! later TMTR is dropped on the floor until software clears the byte.
//!
//! ra8_canfd_frame.c's ra8_canfd_transmit opens with exactly that clear,
//! and its comment records the symptom of not doing it: "After the first
//! successful TX the chip leaves TMTRF=10b ("transmission successful")
//! and silently drops every subsequent TXREQ -- the symptom is the first
//! round-trip working and every later one returning no_data."
//!
//!   CFDTMSTS[0]  +0x074, one byte per mailbox, four mailboxes
//!     TMTSTS [0]    the request is in progress
//!     TMTRF  [2:1]  00b none, 01b aborted, 10b complete, 11b both
//!
//! ONLY TMTRF IS MODELLED. TMTSTS would need a notion of a transmit that
//! takes time, and nothing in this emulator has one: a frame goes the
//! instant TMTR is written. The other three mailboxes are not modelled
//! either, so a store that names only the bytes above CFDTMSTS[0] is left
//! to the caller to count.

/// CFDTMSTS[0]. Bytes +1..+3 are mailboxes 1..3.
pub const off_tmsts0: u32 = 0x074;

pub const field = struct {
    /// TMTRF, the two-bit result.
    pub const tmtrf: u32 = 0x06;
    /// TMTRF = 10b, transmission complete.
    pub const tmtrf_done: u32 = 0x04;
};

/// CFDTMSTS[0] and the requests it turned away.
pub const Status = struct {
    word: u32 = 0,
    /// Transmit requests dropped because a result was still standing.
    stalled: u32 = 0,

    /// Is the mailbox free to take a request?
    pub fn idle(self: Status) bool {
        return self.word & field.tmtrf == 0;
    }

    pub fn done(self: Status) bool {
        return self.word & field.tmtrf == field.tmtrf_done;
    }

    /// The controller finished a transmit.
    pub fn complete(self: *Status) void {
        self.word = (self.word & ~field.tmtrf) | field.tmtrf_done;
    }

    /// Take a store of CFDTMSTS[0]. Software clears TMTRF and can never
    /// set it, so a bit only survives when it was already standing AND the
    /// store leaves it standing.
    pub fn store(self: *Status, value: u32) void {
        self.word = (value & ~field.tmtrf) | (self.word & value & field.tmtrf);
    }

    /// Would a TMTR write now be taken? Counts the refusal when it would
    /// not, so the report can say the run lost frames this way.
    pub fn accepts(self: *Status) bool {
        if (self.idle()) return true;
        self.stalled +%= 1;
        return false;
    }

    pub fn quiet(self: Status) bool {
        return self.word == 0 and self.stalled == 0;
    }
};
