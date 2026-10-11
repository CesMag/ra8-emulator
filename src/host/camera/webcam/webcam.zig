//! The host webcam source's parts (RA8EMU-506): the consent gate, the
//! V4L2 ABI it speaks, the capture-format negotiation, the open node and
//! the frame source over it.
pub const consent = @import("consent.zig");
pub const privacy = @import("privacy.zig");
pub const av_permission = @import("../av_permission.zig");
pub const av_info_plist = @import("../av_info_plist.zig");
pub const av_frame = @import("../av_frame.zig");
pub const av_delegate = @import("../av_delegate.zig");
pub const av_objc = @import("../av_objc.zig");
pub const av_session = @import("../av_session.zig");
pub const av_webcam = @import("../av_webcam.zig");
pub const v4l2 = @import("../v4l2_abi.zig");
pub const negotiate = @import("../v4l2_negotiate.zig");
pub const device = @import("../v4l2_device.zig");
pub const stream = @import("../v4l2_stream.zig");
pub const input = @import("input.zig");
pub const open = @import("open.zig");
pub const mf = @import("../mf_abi.zig");
pub const mf_com = @import("../mf_com.zig");
pub const mf_open = @import("../mf_open.zig");
pub const mf_capture = @import("../mf_capture.zig");
pub const mf_webcam = @import("../mf_webcam.zig");
