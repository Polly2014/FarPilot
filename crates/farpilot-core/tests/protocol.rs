use farpilot_core::frame::{ControlFrame, FrameCodec, ProtocolError};
use farpilot_core::limits::{MAX_CONTROL_FRAME_BYTES, MAX_TERMINAL_FRAME_BYTES, PROTOCOL_VERSION};
use uuid::Uuid;

#[test]
fn control_frame_round_trips_with_explicit_version() {
    let frame = ControlFrame::Ping { nonce: 42 };

    let bytes = FrameCodec::encode_control(&frame).expect("ping should encode");
    let json: serde_json::Value = serde_json::from_slice(&bytes).expect("wire value is JSON");

    assert_eq!(json["version"], PROTOCOL_VERSION);
    assert_eq!(json["type"], "ping");
    assert_eq!(FrameCodec::decode_control(&bytes).unwrap(), frame);
}

#[test]
fn oversized_control_frame_is_rejected() {
    let bytes = vec![b'x'; MAX_CONTROL_FRAME_BYTES + 1];

    assert_eq!(
        FrameCodec::decode_control(&bytes),
        Err(ProtocolError::FrameTooLarge)
    );
}

#[test]
fn unsupported_control_version_is_rejected() {
    let bytes = br#"{"version":2,"type":"ping","nonce":1}"#;

    assert_eq!(
        FrameCodec::decode_control(bytes),
        Err(ProtocolError::UnsupportedVersion(2))
    );
}

#[test]
fn unknown_control_frame_type_is_rejected_without_panicking() {
    let bytes = br#"{"version":1,"type":"surprise","value":1}"#;

    assert_eq!(
        FrameCodec::decode_control(bytes),
        Err(ProtocolError::InvalidControlFrame)
    );
}

#[test]
fn unknown_control_frame_field_is_rejected() {
    let bytes = br#"{"version":1,"type":"ping","nonce":1,"extra":true}"#;

    assert_eq!(
        FrameCodec::decode_control(bytes),
        Err(ProtocolError::InvalidControlFrame)
    );
}

#[test]
fn terminal_data_round_trips_with_channel_id() {
    let channel_id = Uuid::new_v4();

    let bytes = FrameCodec::encode_terminal(channel_id, b"hello").expect("payload should encode");
    let decoded = FrameCodec::decode_terminal(&bytes).expect("payload should decode");

    assert_eq!(decoded.channel_id, channel_id);
    assert_eq!(&decoded.payload[..], b"hello");
}

#[test]
fn truncated_terminal_header_is_rejected() {
    let bytes = vec![0_u8; 17];

    assert_eq!(
        FrameCodec::decode_terminal(&bytes),
        Err(ProtocolError::InvalidTerminalFrame)
    );
}

#[test]
fn unsupported_terminal_version_is_rejected() {
    let mut bytes = FrameCodec::encode_terminal(Uuid::new_v4(), b"hello").unwrap();
    bytes[0..2].copy_from_slice(&2_u16.to_be_bytes());

    assert_eq!(
        FrameCodec::decode_terminal(&bytes),
        Err(ProtocolError::UnsupportedVersion(2))
    );
}

#[test]
fn oversized_terminal_payload_is_rejected() {
    let payload = vec![0_u8; MAX_TERMINAL_FRAME_BYTES + 1];

    assert_eq!(
        FrameCodec::encode_terminal(Uuid::new_v4(), &payload),
        Err(ProtocolError::FrameTooLarge)
    );
}
