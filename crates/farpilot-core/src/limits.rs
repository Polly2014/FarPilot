/// Current FarPilot wire-protocol version.
pub const PROTOCOL_VERSION: u16 = 1;

/// Maximum serialized size of a JSON control frame.
pub const MAX_CONTROL_FRAME_BYTES: usize = 64 * 1024;

/// Maximum payload size of one terminal-data frame.
pub const MAX_TERMINAL_FRAME_BYTES: usize = 256 * 1024;

/// Maximum simultaneous terminal channels admitted for one Host.
pub const MAX_CHANNELS_PER_HOST: usize = 16;

/// Maximum queued terminal bytes before closing a slow channel.
pub const MAX_PENDING_BYTES_PER_CHANNEL: usize = 1024 * 1024;
