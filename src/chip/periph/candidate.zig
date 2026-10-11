//! A pending exception and the priority it would run at.
//!
//! Lower is more urgent, the architecture's convention (DDI0553 B3.6), kept
//! that way so the comparisons here read the way the manual does.
//!
//! This sits in its own file because the pick is no longer only a choice:
//! src/chip/periph/passed.zig wants the candidate that LOST, and asking
//! src/chip/periph/nvic/nvic.zig for the type would put the two files in a cycle.

/// One exception that could be taken right now.
pub const Candidate = struct {
    number: u16,
    priority: u8,
    /// SysTick or PendSV pended in the Non-secure copy of ICSR (RA8EMU-438).
    non_secure: bool = false,
};

/// The more urgent of two candidates. Ties go to the lower exception number,
/// which is what the architecture does.
pub fn better(current: ?Candidate, candidate: Candidate) Candidate {
    const standing = current orelse return candidate;
    if (candidate.priority < standing.priority) return candidate;
    if (candidate.priority == standing.priority and candidate.number < standing.number) return candidate;
    return standing;
}

/// Which of two candidates loses, given the winner `better` returned. Null
/// when there was nothing to lose because `current` was empty.
pub fn loser(current: ?Candidate, candidate: Candidate, winner: Candidate) ?Candidate {
    const standing = current orelse return null;
    return if (winner.number == candidate.number) standing else candidate;
}
