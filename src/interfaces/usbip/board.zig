//! Which device the usbip bridge exports (RA8EMU-75 slice 3c): the board's
//! own USBFS device, the CDC ACM port the firmware presents on the FS jack.
//! Its descriptors are read off the scripted host that enumerates that jack
//! when no cable is in, so the bridge shows a host exactly what the
//! firmware answered and never a copy kept by hand.
const usbfs = @import("ra8_chip").periph.usbfs;
const wire = @import("wire.zig");
const exp = @import("exported.zig");

/// Where the FS jack sits on the emulated bus: one root port, full speed.
pub const fs_place = exp.Place{
    .path = "/sys/devices/ra8/usbfs",
    .busid = "1-1",
    .speed = .full,
};

/// The FS device as an export, once the scripted host has enumerated it.
/// Null until enumeration finishes; an error when what the firmware sent
/// is not a device and configuration descriptor at all.
pub fn fsExport(script: *const usbfs.host.Host) exp.Error!?exp.Export {
    if (!script.done()) return null;
    return try exp.fromDescriptors(fs_place, &script.device, script.configuration());
}
