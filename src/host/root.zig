//! ra8_host: everything that touches the host OS (ADR 0004 section 2,
//! knowledge base article RA8EMU-A-2). Sockets and readiness, the console
//! and handle readers, camera capture backends and image decoders, and
//! file-backed media. It imports only std. Libraries below the applications
//! never import it: a component that needs host data declares an interface,
//! and the application fills it from here.
pub const host_profiles = @import("host_profiles.zig");
pub const host_sock = @import("host_sock.zig");
pub const host_sock_windows = @import("host_sock_windows.zig");
pub const sock_ready = @import("sock_ready.zig");
pub const win32 = @import("win32.zig");
pub const host_console = @import("host_console.zig");
pub const host_read = @import("host_read.zig");
pub const tape_dir = @import("tape_dir.zig");
pub const worker = @import("worker.zig");
pub const disk_file = @import("disk_file.zig");
pub const socket_flags = @import("socket_flags.zig");
pub const folder = @import("folder.zig");
pub const pipe_windows = @import("camera/pipe_windows.zig");
/// Host camera capture backends and file formats (RA8EMU-1011).
pub const camera = struct {
    pub const consent = @import("camera/webcam_consent.zig");
    pub const privacy = @import("camera/webcam_privacy.zig");
    pub const av_permission = @import("camera/av_permission.zig");
    pub const av_info_plist = @import("camera/av_info_plist.zig");
    pub const av_frame = @import("camera/av_frame.zig");
    pub const av_delegate = @import("camera/av_delegate.zig");
    pub const av_objc = @import("camera/av_objc.zig");
    pub const av_session = @import("camera/av_session.zig");
    pub const v4l2 = @import("camera/v4l2_abi.zig");
    pub const negotiate = @import("camera/v4l2_negotiate.zig");
    pub const device = @import("camera/v4l2_device.zig");
    pub const stream = @import("camera/v4l2_stream.zig");
    pub const mf = @import("camera/mf_abi.zig");
    pub const mf_com = @import("camera/mf_com.zig");
    pub const mf_open = @import("camera/mf_open.zig");
    pub const y4m = @import("camera/y4m_header.zig");
    pub const y4m_frame = @import("camera/y4m_frame.zig");
    pub const pipe_frame = @import("camera/pipe_frame.zig");
    pub const decoded = @import("camera/decoded_image.zig");
    pub const ppm = @import("camera/ppm_decode.zig");
    pub const bmp = @import("camera/bmp_decode.zig");
    pub const png = @import("camera/png_decode.zig");
    pub const image_file = @import("camera/image_file.zig");
    pub const video_file = @import("camera/video_file.zig");
    pub const pipe_input = @import("camera/pipe_input.zig");
    pub const webcam = @import("camera/webcam.zig");
    pub const source_spec = @import("camera/source_spec.zig");
    pub const source_open = @import("camera/source_open.zig");
};
