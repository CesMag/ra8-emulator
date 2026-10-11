//! Where a decoded block stops (RA8EMU-403): after the first instruction
//! that can write the PC or change how the next one runs.
//!
//! The test reads the encoding, not the decode group, so a group added later
//! needs no flag here. It is conservative on purpose: a block that ends early
//! only costs a lookup, and the run loop still checks the PC after each
//! instruction, so an instruction this misses cannot run the wrong code.
const Instr = @import("../instr.zig").Instr;

/// Whether `instr` ends a block.
pub fn endsBlock(instr: Instr) bool {
    return if (instr.size == 2) narrowEnds(instr.hw1) else wideEnds(instr.hw1, instr.hw2);
}

fn narrowEnds(hw1: u16) bool {
    if (hw1 & 0xFF00 == 0xBF00) return hw1 & 0x000F != 0; // IT; NOP-class hints go on
    if (hw1 & 0xFF00 == 0xBE00) return true; // BKPT
    if (hw1 & 0xF000 == 0xD000) return true; // B<cond>, UDF, SVC
    if (hw1 & 0xF800 == 0xE000) return true; // B
    if (hw1 & 0xFF00 == 0x4700) return true; // BX, BLX, BXNS, BLXNS
    if (hw1 & 0xFC00 == 0x4400) return hw1 & 0x0087 == 0x0087; // ADD/MOV/CMP, Rdn = PC
    if (hw1 & 0xFF00 == 0xBD00) return true; // POP {..., pc}
    return hw1 & 0xF500 == 0xB100; // CBZ, CBNZ
}

fn wideEnds(hw1: u16, hw2: u16) bool {
    // Branches, BL, LOB, MSR/MRS, barriers and the other misc control forms.
    if (hw1 & 0xF800 == 0xF000) return hw2 & 0x8000 != 0;
    // Loads from the multiple/dual/exclusive/table block listing the PC,
    // which also covers TBB/TBH and SG.
    if (hw1 & 0xFE00 == 0xE800 or hw1 & 0xFE00 == 0xE900) return hw1 & 0x0010 != 0 and hw2 & 0x8000 != 0;
    // Single loads into the PC (PLD shares Rt = 15 and ends a block too).
    if (hw1 & 0xFE00 == 0xF800) return hw1 & 0x0010 != 0 and hw2 & 0xF000 == 0xF000;
    return false;
}
