//! The panel's ready line, driven from the board so an HRDY poll reads a
//! level rather than a floating zero. Matches the epaper app's busy pin.
pub const port: u8 = 4;
pub const pin: u4 = 1;
