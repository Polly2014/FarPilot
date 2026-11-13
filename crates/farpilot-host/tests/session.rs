use std::time::Duration;

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
        registry.input(channel_id, b"late input").await,
        Err(HostSessionError::SessionClosed)
    );
    assert_eq!(
        session.recv().await,
        Some(HostSessionEvent::Close(SessionCloseReason::ClientClosed))
    );
    assert_eq!(registry.len().await, 1);
    registry.finish(channel_id).await;
    assert_eq!(registry.len().await, 0);
}

#[tokio::test]
async fn full_event_queue_fails_fast_and_close_all_does_not_block() {
    let registry = HostSessionRegistry::new(1);
    let channel_id = Uuid::new_v4();
    let mut session = registry.open(channel_id).await.unwrap();

    for _ in 0..64 {
        registry.input(channel_id, b"queued").await.unwrap();
    }
    assert_eq!(
        tokio::time::timeout(
            Duration::from_millis(100),
            registry.input(channel_id, b"overflow")
        )
        .await
        .expect("a full event queue must fail without blocking"),
        Err(HostSessionError::QueueFull)
    );
    tokio::time::timeout(
        Duration::from_millis(100),
        registry.close_all(SessionCloseReason::HostDisconnected),
    )
    .await
    .expect("disconnect cleanup must not wait for event queue capacity");
    assert_eq!(registry.len().await, 1);

    let mut saw_close = false;
    for _ in 0..=64 {
        if matches!(
            session.recv().await,
            Some(HostSessionEvent::Close(
                SessionCloseReason::HostDisconnected
            ))
        ) {
            saw_close = true;
            break;
        }
    }
    assert!(
        saw_close,
        "the close signal must bypass the full event queue"
    );
    registry.finish(channel_id).await;
    assert!(registry.is_empty().await);
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
