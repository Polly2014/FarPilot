use farpilot_core::frame::SessionCloseReason;
use farpilot_host::session::{HostSessionError, HostSessionEvent, HostSessionRegistry};
use uuid::Uuid;

#[tokio::test]
async fn session_registry_routes_input_resize_and_close() {
    let registry = HostSessionRegistry::new(2);
    let channel_id = Uuid::new_v4();
    let mut session = registry.open(channel_id).await.unwrap();

    registry.input(channel_id, b"hello").await.unwrap();
    assert_eq!(
        session.recv().await,
        Some(HostSessionEvent::Input(b"hello".as_slice().into()))
    );
    registry.resize(channel_id, 120, 40).await.unwrap();
    assert_eq!(
        session.recv().await,
        Some(HostSessionEvent::Resize {
            cols: 120,
            rows: 40
        })
    );
    registry
        .close(channel_id, SessionCloseReason::ClientClosed)
        .await
        .unwrap();
    assert_eq!(
        session.recv().await,
        Some(HostSessionEvent::Close(SessionCloseReason::ClientClosed))
    );
    assert_eq!(registry.len().await, 0);
}

#[tokio::test]
async fn duplicate_unknown_and_over_limit_channels_are_rejected() {
    let registry = HostSessionRegistry::new(1);
    let channel_id = Uuid::new_v4();
    let _session = registry.open(channel_id).await.unwrap();

    assert_eq!(
        registry.open(channel_id).await.unwrap_err(),
        HostSessionError::DuplicateChannel
    );
    assert_eq!(
        registry.open(Uuid::new_v4()).await.unwrap_err(),
        HostSessionError::LimitExceeded
    );
    assert_eq!(
        registry.input(Uuid::new_v4(), b"unknown").await,
        Err(HostSessionError::UnknownChannel)
    );
}
