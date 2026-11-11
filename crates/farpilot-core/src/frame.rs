use bytes::Bytes;
use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

use crate::limits::{MAX_CONTROL_FRAME_BYTES, MAX_TERMINAL_FRAME_BYTES, PROTOCOL_VERSION};

const TERMINAL_HEADER_BYTES: usize = 2 + 16;

/// A versioned control message exchanged by Gateway and Host.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum ControlFrame {
    HostHello {
        host_id: String,
        public_key: String,
    },
    HostChallenge {
        challenge: String,
        expires_at_ms: u64,
    },
    HostProof {
        host_id: String,
        signature: String,
    },
    HostReady {
        host_id: String,
    },
    PairingCreate {
        request_id: Uuid,
    },
    PairingCreated {
        request_id: Uuid,
        pairing_url: String,
        secret: String,
        expires_at_ms: u64,
    },
    SessionOpen {
        channel_id: Uuid,
        device_id: String,
        cols: u16,
        rows: u16,
    },
    SessionOpened {
        channel_id: Uuid,
    },
    SessionRefused {
        channel_id: Uuid,
        reason: SessionRefusalReason,
    },
    TerminalResize {
        channel_id: Uuid,
        cols: u16,
        rows: u16,
    },
    Ping {
        nonce: u64,
    },
    Pong {
        nonce: u64,
    },
    SessionClose {
        channel_id: Uuid,
        reason: SessionCloseReason,
    },
    SessionExited {
        channel_id: Uuid,
        exit_code: Option<i32>,
    },
    ProtocolError {
        code: ProtocolErrorCode,
    },
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionRefusalReason {
    HostOffline,
    Unauthorized,
    Busy,
    LimitExceeded,
    Unsupported,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionCloseReason {
    ClientClosed,
    HostDisconnected,
    SlowConsumer,
    ProtocolViolation,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ProtocolErrorCode {
    InvalidFrame,
    Unauthorized,
    LimitExceeded,
    UnsupportedVersion,
}

#[derive(Debug, Deserialize, Serialize)]
struct ControlEnvelope {
    version: u16,
    #[serde(flatten)]
    frame: ControlFrame,
}

/// Decoded terminal bytes for one logical session.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TerminalFrame {
    pub channel_id: Uuid,
    pub payload: Bytes,
}

/// Errors that are safe to expose as protocol-level failure classes.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum ProtocolError {
    #[error("frame exceeds the protocol size limit")]
    FrameTooLarge,
    #[error("control frame is malformed")]
    InvalidControlFrame,
    #[error("terminal frame is malformed")]
    InvalidTerminalFrame,
    #[error("unsupported protocol version {0}")]
    UnsupportedVersion(u16),
}

/// Stateless FarPilot wire codec.
pub struct FrameCodec;

impl FrameCodec {
    pub fn encode_control(frame: &ControlFrame) -> Result<Vec<u8>, ProtocolError> {
        let envelope = ControlEnvelope {
            version: PROTOCOL_VERSION,
            frame: frame.clone(),
        };
        let bytes =
            serde_json::to_vec(&envelope).map_err(|_| ProtocolError::InvalidControlFrame)?;
        if bytes.len() > MAX_CONTROL_FRAME_BYTES {
            return Err(ProtocolError::FrameTooLarge);
        }
        Ok(bytes)
    }

    pub fn decode_control(bytes: &[u8]) -> Result<ControlFrame, ProtocolError> {
        if bytes.len() > MAX_CONTROL_FRAME_BYTES {
            return Err(ProtocolError::FrameTooLarge);
        }

        let value: serde_json::Value =
            serde_json::from_slice(bytes).map_err(|_| ProtocolError::InvalidControlFrame)?;
        let version = value
            .get("version")
            .and_then(serde_json::Value::as_u64)
            .and_then(|version| u16::try_from(version).ok())
            .ok_or(ProtocolError::InvalidControlFrame)?;
        if version != PROTOCOL_VERSION {
            return Err(ProtocolError::UnsupportedVersion(version));
        }

        serde_json::from_value::<ControlEnvelope>(value)
            .map(|envelope| envelope.frame)
            .map_err(|_| ProtocolError::InvalidControlFrame)
    }

    pub fn encode_terminal(channel_id: Uuid, payload: &[u8]) -> Result<Vec<u8>, ProtocolError> {
        if payload.len() > MAX_TERMINAL_FRAME_BYTES {
            return Err(ProtocolError::FrameTooLarge);
        }

        let mut bytes = Vec::with_capacity(TERMINAL_HEADER_BYTES + payload.len());
        bytes.extend_from_slice(&PROTOCOL_VERSION.to_be_bytes());
        bytes.extend_from_slice(channel_id.as_bytes());
        bytes.extend_from_slice(payload);
        Ok(bytes)
    }

    pub fn decode_terminal(bytes: &[u8]) -> Result<TerminalFrame, ProtocolError> {
        if bytes.len() < TERMINAL_HEADER_BYTES {
            return Err(ProtocolError::InvalidTerminalFrame);
        }
        if bytes.len() - TERMINAL_HEADER_BYTES > MAX_TERMINAL_FRAME_BYTES {
            return Err(ProtocolError::FrameTooLarge);
        }

        let version = u16::from_be_bytes([bytes[0], bytes[1]]);
        if version != PROTOCOL_VERSION {
            return Err(ProtocolError::UnsupportedVersion(version));
        }

        let channel_id = Uuid::from_slice(&bytes[2..TERMINAL_HEADER_BYTES])
            .map_err(|_| ProtocolError::InvalidTerminalFrame)?;
        let payload = Bytes::copy_from_slice(&bytes[TERMINAL_HEADER_BYTES..]);
        Ok(TerminalFrame {
            channel_id,
            payload,
        })
    }
}
